// SPDX-License-Identifier: GPL-3.0-only
// solhint-disable no-empty-blocks
pragma solidity ^0.7.5;

import "@ensdomains/ens/contracts/ENS.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// commitments are kept in a seperate contract to allow the state to be reused
// between different versions of the registrar
contract Commitments {
    address public owner;
    modifier auth { require(msg.sender == owner, "Commitments: unauthorized"); _; }
    event SetOwner(address usr);

    /// Mapping from the commitment to the block number in which the commitment was made
    mapping(bytes32 => uint) public commited;

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address usr) external auth {
        owner = usr;
        emit SetOwner(usr);
    }

    function commit(bytes32 commitment) external auth {
        commited[commitment] = block.number;
    }

    function mkCommitment(
        string calldata name, address owner, uint salt
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(name, owner, salt));
    }
}

contract Registrar {

    // --- DATA ---

    /// The ENS registry.
    ENS public ens;

    /// The Radicle ERC20 token.
    ERC20Burnable public immutable rad;

    /// The commitment storage contract
    Commitments public immutable commitments = new Commitments();

    /// The namehash of the `eth` TLD in the ENS registry, eg. namehash("eth").
    bytes32 public constant ethNode = keccak256(abi.encodePacked(bytes32(0), keccak256("eth")));

    /// The namehash of the node in the `eth` TLD, eg. namehash("radicle.eth").
    bytes32 public constant radNode = keccak256(abi.encodePacked(ethNode, keccak256("radicle")));

    /// The token ID for the node in the `eth` TLD, eg. sha256("radicle").
    uint256 public constant tokenId = uint(keccak256(abi.encodePacked("radicle")));

    /// The minimum number of blocks that must have passed between a commitment and name registration
    // TODO: justify this as a default value...
    uint256 public minCommitmentAge = 50;

    /// Registration fee in *Radicle* (uRads).
    uint256 public fee = 1e18;

    // --- LOGS ---

    /// @notice A name was registered.
    event NameRegistered(string indexed name, bytes32 indexed label, address indexed owner);

    /// @notice A commitment was made
    event CommitmentMade(bytes32 commitment, uint blockNumber);

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

    /// @notice The ens registry was updated
    event EnsChanged(address ens);

    /// @notice The minimum age for a commitment was changed
    event MinCommitmentAgeChanged(uint256 amt);

    // -- MATH --

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, "Registrar: overflow during addition");
    }

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

    /// Commit to a future name registration
    function commit(bytes32 commitment) external {
        require(commitments.commited(commitment) == 0, "Registrar::commit: already commited");
        require(rad.balanceOf(msg.sender) >= fee, "Registrar::register: insufficient rad balance");

        rad.burnFrom(msg.sender, fee);
        commitments.commit(commitment);

        emit CommitmentMade(commitment, block.number);
    }

    /// Register a subdomain (with the default resolver and ttl)
    function register(string calldata name, address owner, uint salt) external {
        register(name, owner, salt, ens.resolver(radNode), 0);
    }

    /// Register a subdomain (with a custom resolver and ttl)
    function register(
        string memory name, address owner, uint salt, address resolver, uint64 ttl
    ) public {
        bytes32 label = keccak256(bytes(name));
        bytes32 commitment = commitments.mkCommitment(name, owner, salt);
        uint256 commited = commitments.commited(commitment);

        require(valid(name), "Registrar::register: invalid name");
        require(available(name), "Registrar::register: name has already been registered");
        require(commited != 0, "Registrar::register: must commit before registration");
        require(commited + minCommitmentAge < block.number, "Registrar::register: commitment too new");

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
        require(ethRegistrar.ownerOf(tokenId) == address(this), "HI");
        ethRegistrar.transferFrom(address(this), newOwner, tokenId);
        commitments.setOwner(newOwner);

        emit DomainOwnershipChanged(newOwner);
    }

    /// Set a new resolver for radicle.eth.
    function setDomainResolver(address resolver) public adminOnly {
        ens.setResolver(radNode, resolver);
        emit ResolverChanged(resolver);
    }

    /// Set a new ttl for radicle.eth
    function setDomainTTL(uint64 ttl) public adminOnly {
        ens.setTTL(radNode, ttl);
        emit TTLChanged(ttl);
    }

    /// Set the minimum commitment age
    function setMinCommitmentAge(uint256 amt) public adminOnly {
        minCommitmentAge = amt;
        emit MinCommitmentAgeChanged(amt);
    }

    /// Set a new registration fee
    function setRegistrationFee(uint256 amt) public adminOnly {
        fee = amt;
        emit RegistrationFeeChanged(amt);
    }

    /// Set a new admin
    function setAdmin(address newAdmin) public adminOnly {
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    /// Set the address for the ENS registry
    function setEns(address newEns) public adminOnly {
        ens = ENS(newEns);
        emit EnsChanged(newEns);
    }
}
