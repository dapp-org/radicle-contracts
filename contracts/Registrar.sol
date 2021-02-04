// SPDX-License-Identifier: GPL-3.0-only
// solhint-disable no-empty-blocks
pragma solidity ^0.7.5;

import "@ensdomains/ens/contracts/ENS.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract Registrar {
    /// The ENS registry.
    ENS public immutable ens;

    /// The Radicle ERC20 token.
    ERC20Burnable public immutable rad;

    /// The namehash of the node in the `eth` TLD, eg. namehash("radicle.eth").
    bytes32 public immutable domain;

    /// The token ID for the node in the `eth` TLD, eg. sha256("radicle").
    uint256 public immutable tokenId;

    /// Registration fee in *Radicle* (uRads).
    uint256 public registrationFeeRad = 1e18;

    /// The contract admin who can set fees.
    address public admin;

    /// @notice A name was registered.
    event NameRegistered(bytes32 indexed label, address indexed owner);

    /// Protects admin-only functions.
    modifier adminOnly {
        require(msg.sender == admin, "Only the admin can perform this action");
        _;
    }

    constructor(
        ENS _ens,
        bytes32 ethDomainNameHash,
        uint256 ethDomainTokenId,
        ERC20Burnable _rad,
        address adminAddress
    ) {
        ens = _ens;
        rad = _rad;
        domain = ethDomainNameHash;
        tokenId = ethDomainTokenId;
        admin = adminAddress;
    }

    /// Register a subdomain using radicle tokens.
    function registerRad(string memory name, address owner) public {
        uint256 fee   = registrationFeeRad;
        bytes32 label = keccak256(bytes(name));

        require(rad.balanceOf(msg.sender) >= fee, "Registrar::registerRad: insufficient rad balance");
        require(available(name), "Registrar::registerRad: name has already been registered");
        require(valid(name), "Registrar::registerRad: invalid name");

        rad.burnFrom(msg.sender, fee);
        ens.setSubnodeOwner(domain, label, owner);

        emit NameRegistered(label, owner);
    }

    /// Check whether a name is valid.
    function valid(string memory name) public pure returns (bool) {
        uint256 len = bytes(name).length;
        return len > 0 && len <= 32;
    }

    /// Check whether a name is available for registration.
    function available(string memory name) public view returns (bool) {
        bytes32 label = keccak256(bytes(name));
        bytes32 node = namehash(domain, label);

        return !ens.recordExists(node);
    }

    /// Get the "namehash" of a label.
    function namehash(bytes32 parent, bytes32 label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, label));
    }

    // ADMIN FUNCTIONS

    /// Set the owner of the domain.
    function setDomainOwner(address newOwner) public adminOnly {
        // The name hash of 'eth'
        bytes32 ethNode = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;
        address ethRegistrarAddr = ens.owner(ethNode);
        require(
            ethRegistrarAddr != address(0),
            "Registrar::setDomainOwner: no registrar found on ENS for the 'eth' domain"
        );
        ens.setRecord(domain, newOwner, newOwner, 0);
        IERC721 ethRegistrar = IERC721(ethRegistrarAddr);
        ethRegistrar.transferFrom(address(this), newOwner, tokenId);
    }

    /// Set a new admin
    function setAdmin(address _admin) public adminOnly {
        admin = _admin;
    }
}
