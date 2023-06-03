// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

contract NydusERC721 is ERC721Upgradeable {
    error Forbidden();
    error InvalidParams();

    address public network;
    mapping(uint256 => string) internal _tokenURI;

    modifier onlyNetwork() {
        if (msg.sender != network) revert Forbidden();
        _;
    }

    function initialize(string memory _name, string memory _symbol) external initializer {
        __ERC721_init(_name, _symbol);
        network = msg.sender;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return _tokenURI[tokenId];
    }

    function mint(
        address to,
        uint256 tokenId,
        string calldata uri
    ) external onlyNetwork {
        _safeMint(to, tokenId);
        _tokenURI[tokenId] = uri;
    }

    function mintBatch(
        address[] calldata recipients,
        uint256[] calldata tokenIds,
        string[] calldata uris
    ) external onlyNetwork {
        if (recipients.length != tokenIds.length || tokenIds.length != uris.length) revert InvalidParams();

        for (uint256 i = 0; i < recipients.length; i++) {
            _safeMint(recipients[i], tokenIds[i]);
            _tokenURI[tokenIds[i]] = uris[i];
        }
    }

    function burn(uint256 tokenId) external onlyNetwork {
        _burn(tokenId);
        _tokenURI[tokenId] = "";
    }

    function burnBatch(uint256[] calldata tokenIds) external onlyNetwork {
        for (uint256 i; i < tokenIds.length; ) {
            _burn(tokenIds[i]);
            _tokenURI[tokenIds[i]] = "";

            unchecked {
                ++i;
            }
        }
    }
}
