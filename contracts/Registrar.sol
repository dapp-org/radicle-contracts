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

    /// The namehash of the `eth` TLD in the ENS registry, eg. namehash("eth").
    bytes32 public constant ethNode = keccak256(abi.encodePacked(bytes32(0), keccak256("eth")));

    /// The namehash of the node in the `eth` TLD, eg. namehash("radicle.eth").
    bytes32 public constant radNode = keccak256(abi.encodePacked(ethNode, keccak256("radicle")));

    /// The token ID for the node in the `eth` TLD, eg. sha256("radicle").
    uint256 public constant tokenId = uint256(keccak256("radicle"));

    /// Registration fee in *Radicle* (uRads).
    uint256 public registrationFeeRad = 1e18;

    /// The contract admin who can set fees.
    address public admin;

    /// @notice A name was registered.
    event NameRegistered(string indexed name, bytes32 indexed label, address indexed owner);

    /// @notice The contract admin was changed
    event AdminChanged(address newAdmin);

    /// @notice The ownership of the domain was changed
    event DomainOwnershipChanged(address newOwner);

    /// Protects admin-only functions.
    modifier adminOnly {
        require(msg.sender == admin, "Registrar: only the admin can perform this action");
        _;
    }

    constructor(
        ENS _ens,
        ERC20Burnable _rad,
        address _admin
    ) {
        ens = _ens;
        rad = _rad;
        admin = _admin;
    }

    // --- PUBLIC METHODS ---

    /// Register a subdomain using radicle tokens.
    function registerRad(string memory name, address owner) public {
        uint256 fee   = registrationFeeRad;
        bytes32 label = keccak256(bytes(name));

        require(rad.balanceOf(msg.sender) >= fee, "Registrar::registerRad: insufficient rad balance");
        require(available(name), "Registrar::registerRad: name has already been registered");
        require(valid(name), "Registrar::registerRad: invalid name");

        rad.burnFrom(msg.sender, fee);
        ens.setSubnodeOwner(radNode, label, owner);

        emit NameRegistered(name, label, owner);
    }

    /// Check whether a name is valid.
    function valid(string memory name) public pure returns (bool) {
        uint256 len = bytes(name).length;
        return len > 0 && len <= 32;
    }

    /// Check whether a name is available for registration.
    function available(string memory name) public view returns (bool) {
        bytes32 label = keccak256(bytes(name));
        bytes32 node = namehash(radNode, label);
        return ens.owner(node) == address(0);
    }

    /// Get the "namehash" of a label.
    function namehash(bytes32 parent, bytes32 label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, label));
    }

    // --- ADMIN METHODS ---

    /// Set the owner of the domain.
    function setDomainOwner(address newOwner) public adminOnly {
        IERC721 ethRegistrar = IERC721(ens.owner(ethNode));

        ens.setOwner(radNode, newOwner);
        ethRegistrar.transferFrom(address(this), newOwner, tokenId);

        emit DomainOwnershipChanged(newOwner);
    }

    /// Set a new admin
    function setAdmin(address newAdmin) public adminOnly {
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }
}
