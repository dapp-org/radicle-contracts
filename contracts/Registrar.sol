// SPDX-License-Identifier: GPL-3.0-only
// solhint-disable no-empty-blocks
pragma solidity ^0.7.5;

import "@ensdomains/ens/contracts/ENS.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract Registrar {

    // --- DATA ---

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
    uint256 public registrationFee = 1e18;

    // --- LOGS ---

    /// @notice A name was registered.
    event NameRegistered(string indexed name, bytes32 indexed label, address indexed owner);

    /// @notice The contract admin was changed
    event AdminChanged(address newAdmin);

    /// @notice The registration fee was changed
    event RegistrationFeeChanged(uint amt);

    /// @notice The ownership of the domain was changed
    event DomainOwnershipChanged(address newOwner);

    /// @notice The registration fee was changed
    event ResolverChanged(address resolver);

    /// @notice The registration fee was changed
    event TTLChanged(uint64 amt);

    // --- AUTH ---

    /// The contract admin who can set fees.
    address public admin;

    /// Protects admin-only functions.
    modifier adminOnly {
        require(msg.sender == admin, "Registrar: only the admin can perform this action");
        _;
    }

    // --- INIT ---

    constructor(
        ENS _ens,
        ERC20Burnable _rad,
        address _admin
    ) {
        ens = _ens;
        rad = _rad;
        admin = _admin;
    }

    // --- USER FACING METHODS ---

    /// Register a subdomain (with the default resolver and ttl)
    function register(string memory name, address owner) public {
        register(name, owner, ens.resolver(radNode), 0);
    }

    /// Register a subdomain (with a custom resolver and ttl)
    function register(string memory name, address owner, address resolver, uint64 ttl) public {
        uint256 fee   = registrationFee;
        bytes32 label = keccak256(bytes(name));

        require(rad.balanceOf(msg.sender) >= fee, "Registrar::register: insufficient rad balance");
        require(available(name), "Registrar::register: name has already been registered");
        require(valid(name), "Registrar::register: invalid name");

        rad.burnFrom(msg.sender, fee);
        ens.setSubnodeRecord(radNode, label, owner, resolver, ttl);

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

    /// Set a new resolver for radicle.eth
    function setDomainResolver(address resolver) public adminOnly {
        ens.setResolver(radNode, resolver);
        emit ResolverChanged(resolver);
    }

    /// Set a new ttl for radicle.eth
    function setDomainTTL(uint64 ttl) public adminOnly {
        ens.setTTL(radNode, ttl);
        emit TTLChanged(ttl);
    }

    /// Set a new registration fee
    function setRegistrationFee(uint256 amt) public adminOnly {
        registrationFee = amt;
        emit RegistrationFeeChanged(amt);
    }

    /// Set a new admin
    function setAdmin(address newAdmin) public adminOnly {
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }
}
