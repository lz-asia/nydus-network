// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";
import "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";
import "./NydusERC721.sol";

contract NydusNetwork is NonblockingLzApp {
    struct OriginContract {
        uint16 chainId;
        address addr;
    }

    uint16 public constant PT_CREATE = 1;
    uint16 public constant PT_SEND = 2;
    uint16 public constant PT_SEND_BATCH = 3;

    address public immutable implementation;
    uint16 public immutable chainId;

    mapping(address => OriginContract) public originContractOf;

    event OnCreate(address indexed originAddr, uint16 indexed originChainId, address indexed addr);
    event OnSend(address indexed originAddr, uint16 indexed originChainId, uint256 tokenId);
    event OnSendBatch(address indexed originAddr, uint16 indexed originChainId, uint256[] tokenIds);

    error NotOriginChain();
    error NotCreated();
    error UnknownPacketType();

    constructor(address _endpoint, uint16 _chainId) NonblockingLzApp(_endpoint) {
        NydusERC721 nft = new NydusERC721();
        nft.initialize("", "");
        implementation = address(nft);
        chainId = _chainId;
    }

    function create(
        address addr,
        uint16 dstChainId,
        uint256 dstGasForCall
    ) external payable {
        OriginContract memory origin = originContractOf[addr];
        if (origin.addr != address(0)) revert NotOriginChain();

        string memory name;
        try IERC721MetadataUpgradeable(addr).name() returns (string memory _name) {
            name = _name;
        } catch {}
        string memory symbol;
        try IERC721MetadataUpgradeable(addr).symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {}

        _lzSend(
            dstChainId,
            abi.encode(PT_CREATE, addr, name, symbol),
            payable(msg.sender),
            address(0),
            abi.encodePacked(uint16(1), dstGasForCall),
            msg.value
        );
    }

    function sendFrom(
        address addr,
        address from,
        uint256 tokenId,
        uint16 dstChainId,
        address dstRecipient,
        uint256 dstGasForCall
    ) external payable {
        OriginContract memory origin = originContractOf[addr];
        if (origin.addr == address(0)) {
            IERC721Upgradeable(addr).safeTransferFrom(from, address(this), tokenId);
            origin.chainId = chainId;
            origin.addr = addr;
        } else {
            NydusERC721(addr).burn(tokenId);
        }

        _lzSend(
            dstChainId,
            abi.encode(PT_SEND, origin.chainId, origin.addr, tokenId, _tokenUri(addr, tokenId), dstRecipient),
            payable(from),
            address(0),
            abi.encodePacked(uint16(1), dstGasForCall),
            msg.value
        );
    }

    function sendBatchFrom(
        address addr,
        address from,
        uint256[] memory tokenIds,
        uint16 dstChainId,
        address[] memory dstRecipients,
        uint256 dstGasForCall
    ) external payable {
        OriginContract memory origin = originContractOf[addr];
        if (origin.addr == address(0)) {
            for (uint256 i; i < tokenIds.length; ) {
                IERC721Upgradeable(addr).safeTransferFrom(from, address(this), tokenIds[i]);
                unchecked {
                    ++i;
                }
            }
            origin.chainId = chainId;
            origin.addr = addr;
        } else {
            NydusERC721(addr).burnBatch(tokenIds);
        }

        string[] memory tokenUris = new string[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ) {
            tokenUris[i] = _tokenUri(addr, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        _lzSend(
            dstChainId,
            abi.encode(PT_SEND_BATCH, origin.chainId, origin.addr, tokenIds, tokenUris, dstRecipients),
            payable(from),
            address(0),
            abi.encodePacked(uint16(1), dstGasForCall),
            msg.value
        );
    }

    function _tokenUri(address addr, uint256 tokenId) internal view returns (string memory uri) {
        try IERC721MetadataUpgradeable(addr).tokenURI(tokenId) returns (string memory _uri) {
            uri = _uri;
        } catch {}
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory,
        uint64,
        bytes memory _payload
    ) internal override {
        uint16 packetType = abi.decode(_payload, (uint16));
        if (packetType == PT_CREATE) {
            _onCreate(_srcChainId, _payload);
        } else if (packetType == PT_SEND) {
            _onSend(_payload);
        } else if (packetType == PT_SEND_BATCH) {
            _onSendBatch(_payload);
        } else {
            revert UnknownPacketType();
        }
    }

    function _onCreate(uint16 originChainId, bytes memory _payload) internal {
        (, address originAddr, string memory name, string memory symbol) = abi.decode(
            _payload,
            (uint16, address, string, string)
        );

        bytes32 salt = keccak256(abi.encodePacked(originChainId, originAddr));
        address addr = ClonesUpgradeable.cloneDeterministic(implementation, salt);
        NydusERC721(addr).initialize(name, symbol);
        originContractOf[addr] = OriginContract(originChainId, originAddr);

        emit OnCreate(originAddr, originChainId, addr);
    }

    function _onSend(bytes memory _payload) internal {
        (, address originAddr, uint16 originChainId, uint256 tokenId, string memory uri, address recipient) = abi
            .decode(_payload, (uint16, address, uint16, uint256, string, address));

        if (originChainId == chainId) {
            IERC721Upgradeable(originAddr).safeTransferFrom(address(this), recipient, tokenId);
        } else {
            bytes32 salt = keccak256(abi.encodePacked(originChainId, originAddr));
            address addr = ClonesUpgradeable.predictDeterministicAddress(implementation, salt);
            if (addr.code.length == 0) revert NotCreated();

            NydusERC721(addr).mint(recipient, tokenId, uri);
        }

        emit OnSend(originAddr, originChainId, tokenId);
    }

    function _onSendBatch(bytes memory _payload) internal {
        (
            ,
            address originAddr,
            uint16 originChainId,
            uint256[] memory tokenIds,
            string[] memory uris,
            address[] memory recipients
        ) = abi.decode(_payload, (uint16, address, uint16, uint256[], string[], address[]));

        if (originChainId == chainId) {
            for (uint256 i; i < tokenIds.length; ) {
                IERC721Upgradeable(originAddr).safeTransferFrom(address(this), recipients[i], tokenIds[i]);
                unchecked {
                    ++i;
                }
            }
        } else {
            bytes32 salt = keccak256(abi.encodePacked(originChainId, originAddr));
            address addr = ClonesUpgradeable.predictDeterministicAddress(implementation, salt);
            if (addr.code.length == 0) revert NotCreated();

            NydusERC721(addr).mintBatch(recipients, tokenIds, uris);
        }

        emit OnSendBatch(originAddr, originChainId, tokenIds);
    }
}
