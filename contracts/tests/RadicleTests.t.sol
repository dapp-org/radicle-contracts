pragma solidity ^0.7.5;
pragma abicoder v2;

import {Phase0}        from "../deploy/phase0.sol"; 
import {RadicleToken}  from "../Governance/RadicleToken.sol";
import {Governor}      from "../Governance/Governor.sol";
import {Timelock}      from "../Governance/Timelock.sol";
import {VestingToken}  from "../Governance/VestingToken.sol";
import {Registrar, Commitments} from "../Registrar.sol";

import {ENS}           from "@ensdomains/ens/contracts/ENS.sol";
import {ENSRegistry}   from "@ensdomains/ens/contracts/ENSRegistry.sol";
import {IERC721}       from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {DSTest} from "ds-test/test.sol";
import {DSMath} from "ds-math/math.sol";

interface Hevm {
    function warp(uint256) external;
    function roll(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract VestingUser {
    function withdrawVested(VestingToken vest) public {
        vest.withdrawVested();
    }
}

contract VestingOwner {
    function terminateVesting(VestingToken vest) public {
        vest.terminateVesting();
    }
}

contract VestingTokenTests is DSTest, DSMath {
    RadicleToken rad;
    VestingUser user;
    VestingOwner owner;
    Hevm hevm = Hevm(HEVM_ADDRESS);

    function setUp() public {
        hevm.warp(12345678);

        rad = new RadicleToken(address(this));
        user = new VestingUser();
        owner = new VestingOwner();
    }

    // Demonstrates a bug where withdrawableBalance() could revert after
    // vesting has been interrupted.
    function test_vesting_failure() public {
        VestingToken vest = Utils.mkVestingToken(
            address(rad),
            address(this),
            address(user),
            10000000 ether,
            block.timestamp - 1,
            2 weeks,
            1 days
        );

        hevm.warp(block.timestamp + 2 days);
        vest.terminateVesting();
        hevm.warp(block.timestamp + 1 days);

        // withdrawableBalance reverts if vesting was interrupted
        vest.withdrawableBalance();
    }

    // `withdrawableBalance()` should always return the actual amount that will
    // be withdrawan when calling `withdrawVested()`
    function test_withdrawal_amount(
        uint24 jump, uint24 amount, uint8 startOffset, uint24 vestingPeriod, uint24 cliffPeriod
    ) public {
        if (vestingPeriod == 0) return;
        if (startOffset == 0) return;
        if (amount == 0) return;
        if (amount > 10000000 ether) return;

        VestingToken vest = Utils.mkVestingToken(
            address(rad),
            address(this),
            address(user),
            amount,
            block.timestamp - startOffset,
            vestingPeriod,
            cliffPeriod
        );

        hevm.warp(block.timestamp + jump);

        uint amt = vest.withdrawableBalance();
        uint prebal = rad.balanceOf(address(user));

        user.withdrawVested(vest);
        uint postbal = rad.balanceOf(address(user));

        assertEq(postbal - prebal, amt, "withdrawn amount matches withdrawableBalance");
    }

    // The VestingToken should be empty after `terminateVesting()` has been called
    // The beneficiary should have received all vested tokens
    // The owner should have received all unvested tokens
    function test_empty_after_termination(
        uint24 jump, uint24 amount, uint8 startOffset, uint24 vestingPeriod, uint24 cliffPeriod
    ) public {
        if (vestingPeriod == 0) return;
        if (startOffset == 0) return;
        if (amount == 0) return;
        if (amount > 10000000 ether) return;

        VestingToken vest = Utils.mkVestingToken(
            address(rad),
            address(owner),
            address(user),
            amount,
            block.timestamp - startOffset,
            vestingPeriod,
            cliffPeriod
        );

        hevm.warp(block.timestamp + jump);

        assertEq(rad.balanceOf(address(vest)), amount);
        uint vested = vest.withdrawableBalance();
        log_named_uint("vested", vested);
        log_named_uint("amount", amount);
        uint unvested = sub(amount, vest.withdrawableBalance());

        owner.terminateVesting(vest);

        assertEq(
            rad.balanceOf(address(vest)), 0,
            "vesting token is empty"
        );
        assertEq(
            rad.balanceOf(address(user)), vested,
            "beneficiary has received all vested tokens"
        );
        assertEq(
            rad.balanceOf(address(owner)), unvested,
            "owner has received all unvested tokens"
        );
    }

    // The `withdrawn` attribute should always accurately reflect the actual amount withdrawn
    // Demonstrates a bug where the withdrawn attribute is set to a misleading value after termination
    function test_withdrawn_accounting(
        uint8 jump, uint24 amount, uint8 startOffset, uint24 vestingPeriod, uint24 cliffPeriod
    ) public {
        if (vestingPeriod == 0) return;
        if (startOffset == 0) return;
        if (amount == 0) return;
        if (amount > 10000000 ether) return;

        VestingToken vest = Utils.mkVestingToken(
            address(rad),
            address(owner),
            address(user),
            amount,
            block.timestamp - startOffset,
            vestingPeriod,
            cliffPeriod
        );

        uint withdrawn = 0;

        for (uint i; i < 10; i++) {
            hevm.warp(block.timestamp + jump);
            uint prebal = rad.balanceOf(address(user));
            user.withdrawVested(vest);

            uint postbal = rad.balanceOf(address(user));
            withdrawn = add(withdrawn, postbal - prebal);
        }

        assertEq(withdrawn, vest.withdrawn(), "pre-termination");

        hevm.warp(block.timestamp + jump);
        uint withdrawable = vest.withdrawableBalance();
        owner.terminateVesting(vest);

        assertEq(vest.withdrawn(), add(withdrawn, withdrawable), "post-termination");
    }
}

contract RegistrarRPCTests is DSTest {
    ENS ens;
    RadicleToken rad;
    Registrar registrar;
    bytes32 domain;
    uint tokenId;
    Hevm hevm = Hevm(HEVM_ADDRESS);
    Governor gov;

    function setUp() public {
        domain = Utils.namehash(["radicle", "eth"]);
        ens = ENS(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e);
        tokenId = uint(keccak256(abi.encodePacked("radicle"))); // seth keccak radicle
        Phase0 phase0 = new Phase0( address(this)
                                    , 2 days
                                    , address(this)
                                    , ens
                                    , domain
                                    , "radicle"
                                    );
        registrar = phase0.registrar();
        rad = phase0.token();
        gov = phase0.governor();
        log_named_address("Registrar", address(registrar));

        // make this contract the owner of the radicle.eth domain
        hevm.store(
            address(ens),
            keccak256(abi.encodePacked(domain, uint(0))),
            Utils.asBytes32(address(this))
        );

        // make this contract the owner of the radicle.eth 721 token
        address ethRegistrarAddr = ens.owner(Utils.namehash(["eth"]));

        // set owner["radicle"] = address(registrar)
        // TODO: make this less inscrutible
        hevm.store(
            ethRegistrarAddr,
            0x7906724a382e1baec969d07da2f219928e717131ddfd68dbe3d678f62fa3065b,
            Utils.asBytes32(address(this))
        );

        // ownedTokensCount[address(this)]
        // TODO: make this less inscrutible
        hevm.store(
            ethRegistrarAddr,
            bytes32(uint(99769381792979770997497849739242275106480790460331428765085642759382986339262)),
            bytes32(uint(1))
        );

        // transfer ownership of the ENS record to the registrar
        ens.setOwner(domain, address(registrar));

        // transfer ownership of the 721 token to the registrar
        IERC721(ethRegistrarAddr).transferFrom(address(this), address(registrar), tokenId);
    }

    // --- tests ---

    // the ownership of the correct node in ens changes after domain registration
    function test_register(string memory name) public {
        if (bytes(name).length == 0) return;
        if (bytes(name).length > 32) return;
        bytes32 node = Utils.namehash([name, "radicle", "eth"]);

        assertEq(ens.owner(node), address(0));
        registerWith(registrar, name);
        assertEq(ens.owner(node), address(this));
    }

    // BUG: the resolver is address(0x0) for radicle subdomains
    function test_resolverUnset() public {
        bytes32 node = Utils.namehash(["microsoft", "radicle", "eth"]);

        assertEq(ens.owner(node), address(0));
        registerWith(registrar, "microsoft");
        assertEq(ens.owner(node), address(this));
        assertEq(ens.resolver(node), ens.resolver(Utils.namehash(["radicle", "eth"])));
    }


    // BUG: names transfered to the zero address can never be reregistered
    function test_reregistration(string memory name) public {
        if (bytes(name).length == 0) return;
        if (bytes(name).length > 32) return;
        bytes32 node = Utils.namehash([name, "radicle", "eth"]);
        registerWith(registrar, name, 666);

        ens.setOwner(node, address(0));
        assertEq(ens.owner(node), address(0));
        assertTrue(ens.recordExists(node));

        registerWith(registrar, name, 667);
        assertEq(ens.owner(node), address(this));
    }

    // domain registration still works after transfering ownership of the
    // "radicle.eth" domain to a new registrar
    // TODO: the Timelock is the admin of the Registrar,
    // so we will need to make a proposal to perform this transition.
    function test_register_with_new_owner() public {
        string memory name = "mrchico";
        Registrar registrar2 = new Registrar(
            ens,
            rad,
            address(this),
            50,
            domain,
            tokenId
        );
        log_named_address("registrar2", address(registrar2));
        rad.delegate(address(this));
        hevm.roll(block.number + 1);
        // This proposal was generated with `radgov propose newRegistrar`!
        // where newRegistrar is:
        //
        // This proposal migrates the radicle.eth domain and token
        // to a new Registrar.
        //
        // ## PROPOSAL ##
        //
        // ```
        // 0xFCBcd8C32305228F205c841c03f59D2491f92Cb4 0 "setDomainOwner(address)" 0xEcEDFd8BA8ae39a6Bd346Fe9E5e0aBeA687fFF31
        // ```
        (bool success, bytes memory retdata) = address(gov).call(hex"da95691a00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000002200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000fcbcd8c32305228f205c841c03f59d2491f92cb400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000017736574446f6d61696e4f776e6572286164647265737329000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000ecedfd8ba8ae39a6bd346fe9e5e0abea687fff31000000000000000000000000000000000000000000000000000000000000004b546869732070726f706f73616c206d69677261746573207468652072616469636c652e65746820646f6d61696e20616e6420746f6b656e20746f2061206e6577205265676973747261722e000000000000000000000000000000000000000000");
        assertTrue(success);
        uint id = abi.decode(retdata, (uint));
        assertEq(id, 1);
        (address[] memory targets, uint256[] memory values, string[] memory signatures, bytes[] memory calldatas) = gov.getActions(1);
        assertEq(targets[0], address(registrar));
        assertEq(values[0], 0);
        assertEq(signatures[0], "setDomainOwner(address)");
        assertEq0(calldatas[0], abi.encode(address(registrar2)));

        // advance the time and vote the proposal through
        hevm.roll(block.number + gov.votingDelay() + 1);
        assertEq(uint(gov.state(id)), 1, "proposal is active");

        // votes cast must have been checkpointed by delegation, and
        // exceed the quorum and votes against
        gov.castVote(id, true);
        hevm.roll(block.number + gov.votingPeriod());
        assertEq(uint(gov.state(id)), 4, "proposal is successful");

        // queueing succeeds unless already queued
        // (N.B. cannot queue multiple calls to same signature as-is)
        gov.queue(id);
        assertEq(uint(gov.state(id)), 5, "proposal is queued");

        // can only execute following time delay
        hevm.warp(block.timestamp + 2 days);
        gov.execute(id);
        assertEq(uint(gov.state(id)), 7, "proposal is executed");

        // the new registrar is now the owner of the domain
        assertEq(ens.owner(domain), address(registrar2));

        // and so we can register with it
        registerWith(registrar2, name);

        assertEq(ens.owner(Utils.namehash([name, "radicle", "eth"])), address(this));
    }

    // a domain that has already been registered cannot be registered again
    function testFail_double_register(string memory name) public {
        require(bytes(name).length > 0);
        require(bytes(name).length <= 32);

        registerWith(registrar, name);
        registerWith(registrar, name);
    }

    // Utils.nameshash does the right thing for radicle.eth subdomains
    function test_namehash(string memory name) public {
        bytes32 node = Utils.namehash([name, "radicle", "eth"]);
        assertEq(node, keccak256(abi.encodePacked(
            keccak256(abi.encodePacked(
                keccak256(abi.encodePacked(
                    bytes32(uint(0)),
                    keccak256("eth")
                )),
                keccak256("radicle")
            )),
            keccak256(bytes(name))
        )));
    }

    // --- helpers ---

    function registerWith(Registrar reg, string memory name) internal {
        registerWith(reg, name, 42069);
    }

    /* function registerFor(Registrar reg, address owner, string memory name, bytes32 r, bytes32 s, uint8 v, bytes32 permit_r, bytes32 permit_s, uint8 permit_v) internal { */
    /*     uint salt = 150987; */
    /*     bytes32 commitment = keccak256(abi.encodePacked(name, owner, salt)); */
    /*     reg.commitBySigWithPermit(commitment, 0, uint(-1), 1 ether, owner, uint(-1), uint(-1), permit_v, permit_r, permit_s); */
    /*     hevm.roll(block.number + 100); */
    /*     reg.register(name, owner, salt); */
    /* } */

    function registerWith(Registrar reg, string memory name, uint salt) internal {
        uint preBal = rad.balanceOf(address(this));

        bytes32 commitment = keccak256(abi.encodePacked(name, address(this), salt));
        rad.approve(address(reg), uint(-1));

        reg.commit(commitment);
        hevm.roll(block.number + 100);
        reg.register(name, address(this), salt);

        assertEq(rad.balanceOf(address(this)), preBal - 1 ether);
    }
}

contract RadUser {
    RadicleToken rad;
    Governor   gov;
    constructor (RadicleToken rad_, Governor gov_) {
        rad = rad_;
        gov = gov_;
    }
    function delegate(address to) public {
        rad.delegate(to);
    }
    function transfer(address to, uint amt) public {
        rad.transfer(to, amt);
    }
    function burn(uint amt) public {
        rad.burnFrom(address(this), amt);
    }

    function propose(address target, string memory sig, bytes memory cd) public returns (uint) {
        address[] memory targets = new address[](1);
        uint[] memory values = new uint[](1);
        string[] memory sigs = new string[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = target;
        values[0] = 0;
        sigs[0] = sig;
        calldatas[0] = cd;
        return gov.propose(targets, values, sigs, calldatas, "");
    }
    function queue(uint proposalId) public {
        gov.queue(proposalId);
    }
    function castVote(uint proposalId, bool support) public {
        gov.castVote(proposalId, support);
    }
}

contract GovernanceTest is DSTest {
    Governor gov;
    RadicleToken rad;
    RadUser usr;
    RadUser ali;
    RadUser bob;
    RadUser cal;
    Timelock timelock;

    uint x; // only writeable by timelock

    Hevm hevm = Hevm(HEVM_ADDRESS);

    function setUp() public {
        Phase0 phase0 = new Phase0( address(this)
                                  , 2 days
                                  , address(this)
                                  , ENS(address(this))
                                  , "namehash"
                                  , "label"
                                  );

        rad      = phase0.token();
        timelock = phase0.timelock();
        gov      = phase0.governor();

        usr = new RadUser(rad, gov);
        ali = new RadUser(rad, gov);
        bob = new RadUser(rad, gov);
        cal = new RadUser(rad, gov);
        // proposal threshold is 1%
        rad.transfer(address(ali), 500_000 ether);
        rad.transfer(address(bob), 500_001 ether);
        // quorum is 4%
        rad.transfer(address(cal), 5_000_000 ether);
    }

    function test_deploy() public {
        uint gas_before = gasleft();
        Phase0 phase0 = new Phase0( address(this)
                                  , 2 days
                                  , address(this)
                                  , ENS(address(this))
                                  , "namehash"
                                  , "label"
                                  );
        uint gas_after = gasleft();
        log_named_uint("deployment gas", gas_before - gas_after);
    }

    function test_radAddress() public {
        assertEq(address(rad), address(0x25E827B40a7D04de0D177BB228A99F69b83fA7FC));
    }

    function test_domainSeparator() public {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        bytes32 DOMAIN = rad.DOMAIN_SEPARATOR();
        assertEq(DOMAIN,
                 keccak256(
                           abi.encode(
                                      keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                                      keccak256(bytes(rad.NAME())),
                                      chainId,
                                      address(rad))));
        log_named_bytes32("DOMAIN_SEPARATOR()", DOMAIN);
    }

    // generated with
    // export NONCE=0; export ETH_KEYSTORE=./secrets; export ETH_PASSWORD=./secrets/radical; export ETH_FROM=0xd521c744831cfa3ffe472d9f5f9398c9ac806203
    // ./bin/permit 0x25E827B40a7D04de0D177BB228A99F69b83fA7FC 100 -1
    function test_permit() public {
        address owner = 0xD521C744831cFa3ffe472d9F5F9398c9Ac806203;
        assertEq(rad.nonces(owner), 0);
        assertEq(rad.allowance(owner, address(rad)), 0);
        rad.permit(owner, address(rad), 100, uint(-1),
                   28,
                   0xb1b88cc9bdd69831879b406e560b29fc6938d556f8f7be5c580ce11cfd3d354e,
                   0x4ab00b718c09a9f9fb2dd35c2555659bb2b45509b402845bd37b8ef82eb97661);
        assertEq(rad.allowance(owner, address(rad)), 100);
        assertEq(rad.nonces(owner), 1);
    }

    function test_permit_typehash() public {
        assertEq(rad.PERMIT_TYPEHASH(), 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9); // seth keccak $(seth --from-ascii "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    }

    function testFail_permit_replay() public {
        address owner = 0xD521C744831cFa3ffe472d9F5F9398c9Ac806203;
        rad.permit(owner, address(rad), 100, uint(-1),
                   28,
                   0xb1b88cc9bdd69831879b406e560b29fc6938d556f8f7be5c580ce11cfd3d354e,
                   0x4ab00b718c09a9f9fb2dd35c2555659bb2b45509b402845bd37b8ef82eb97661);
        rad.permit(owner, address(rad), 100, uint(-1),
                   28,
                   0xb1b88cc9bdd69831879b406e560b29fc6938d556f8f7be5c580ce11cfd3d354e,
                   0x4ab00b718c09a9f9fb2dd35c2555659bb2b45509b402845bd37b8ef82eb97661);
    }

    function nextBlock() internal {
        hevm.roll(block.number + 1);
    }

    function set_x(uint _x) public {
        require(msg.sender == address(timelock));
        x = _x;
    }

    function test_Delegate(uint96 a, uint96 b, uint96 c, address d, address e) public {
        if (a > 100000000 ether) return;
        if (uint(b) + uint(c) > uint(a)) return;
        if (d == address(0) || e == address(0)) return;
        rad.transfer(address(usr), a);
        usr.delegate(address(usr)); // delegating to self should be a noop
        usr.delegate(d);
        nextBlock();
        assertEq(uint(rad.getCurrentVotes(address(d))), a);
        usr.transfer(e, b);
        nextBlock();
        assertEq(uint(rad.getCurrentVotes(address(d))), a - b);
        usr.burn(c);
        nextBlock();
        assertEq(uint(rad.getPriorVotes(address(d), block.number - 3)), a);
        assertEq(uint(rad.getPriorVotes(address(d), block.number - 2)), a - b);
        assertEq(uint(rad.getPriorVotes(address(d), block.number - 1)), a - b - c);
        assertEq(uint(rad.getCurrentVotes(address(d))), a - b - c);
    }

    function test_propose() public {
        uint proposals = gov.proposalCount();
        ali.delegate(address(bob));
        bob.delegate(address(bob));
        nextBlock();
        bob.propose(address(this), "set_x(uint256)", abi.encode(uint(1)));
        assertEq(gov.proposalCount(), proposals + 1);
    }

    // governance follows the flow:
    //   - propose
    //   - queue
    //   - execute OR cancel
    function test_vote_to_execution() public {
        ali.delegate(address(bob));
        bob.delegate(address(bob));
        cal.delegate(address(cal));
        nextBlock();
        uint id = bob.propose(address(this), "set_x(uint256)", abi.encode(uint(1)));
        assertEq(uint(gov.state(id)), 0 , "proposal is pending");

        // proposal is Pending until block.number + votingDelay + 1
        hevm.roll(block.number + gov.votingDelay() + 1);
        assertEq(uint(gov.state(id)), 1, "proposal is active");

        // votes cast must have been checkpointed by delegation, and
        // exceed the quorum and votes against
        cal.castVote(id, true);
        hevm.roll(block.number + gov.votingPeriod());
        assertEq(uint(gov.state(id)), 4, "proposal is successful");

        // queueing succeeds unless already queued
        // (N.B. cannot queue multiple calls to same signature as-is)
        bob.queue(id);
        assertEq(uint(gov.state(id)), 5, "proposal is queued");

        // can only execute following time delay
        assertEq(x, 0, "x is unmodified");
        hevm.warp(block.timestamp + 2 days);
        gov.execute(id);
        assertEq(uint(gov.state(id)), 7, "proposal is executed");
        assertEq(x, 1, "x is modified");
    }

    /* function testAbiEncode() public { */
    /*     address[] memory targets = new address[](1); */
    /*     uint256[] memory values  = new uint256[](1); */
    /*     string[]  memory sigs    = new string[](1); */
    /*     bytes[]   memory datas   = new bytes[](1); */
    /*     targets[0] = 0xFCBcd8C32305228F205c841c03f59D2491f92Cb4; */
    /*     values[0] = 0; */
    /*     sigs[0] = "setDomainOwner(address)"; */
    /*     datas[0] = abi.encode(address(0xEcEDFd8BA8ae39a6Bd346Fe9E5e0aBeA687fFF31)); */
    /*     bytes memory encoded = abi.encodeWithSignature("propose(address[],uint256[],string[],bytes[],string)", */
    /*                                                    targets, */
    /*                                                    values, */
    /*                                                    sigs, */
    /*                                                    datas, */
    /*                                                    "This proposal migrates the radicle.eth domain and token to a new Registrar."); */
    /*     assertEq0(encoded, hex"da95691a00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000fcbcd8c32305228f205c841c03f59d2491f92cb400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000017736574446f6d61696e4f776e6572286164647265737329000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000ecedfd8ba8ae39a6bd346fe9e5e0abea687fff31000000000000000000000000000000000000000000000000000000000000004b546869732070726f706f73616c206d69677261746573207468652072616469636c652e65746820646f6d61696e20616e6420746f6b656e20746f2061206e6577205265676973747261722e000000000000000000000000000000000000000000"); */
    /* } */
    
    function testAbiEncode2() public {
        string[]  memory sigs    = new string[](1);
        sigs[0] = "setDomainOwner(address)";
        bytes memory encoded = abi.encodeWithSignature("f(string[],string)",
                                                       sigs,
                                                       "This proposal migrates the radicle.eth domain and token to a new Registrar.");
        assertEq0(encoded, hex"07ac501f000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000017736574446f6d61696e4f776e6572286164647265737329000000000000000000000000000000000000000000000000000000000000000000000000000000004b546869732070726f706f73616c206d69677261746573207468652072616469636c652e65746820646f6d61696e20616e6420746f6b656e20746f2061206e6577205265676973747261722e000000000000000000000000000000000000000000");
    }
    
    function testAbiEncode3() public {
        string[]  memory sigs    = new string[](1);
        sigs[0] = "setDomainOwner(address)";
        bytes memory encoded = abi.encodeWithSignature("f(string[])",
                                                       sigs);
        assertEq0(encoded, hex"e9cc87800000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000017736574446f6d61696e4f776e6572286164647265737329000000000000000000");
    }

}

library Utils {
    function create2Address(
        bytes32 salt, address creator, bytes memory creationCode, bytes memory args
    ) internal pure returns (address) {
        return address(uint(keccak256(abi.encodePacked(
            bytes1(0xff),
            creator,
            salt,
            keccak256(abi.encodePacked(creationCode, args))
        ))));
    }

    function mkVestingToken(
        address token,
        address owner,
        address beneficiary,
        uint amount,
        uint vestingStartTime,
        uint vestingPeriod,
        uint cliffPeriod
    ) internal returns (VestingToken) {
        bytes32 salt = bytes32("0xacab");

        address vestAddress = Utils.create2Address(
            salt,
            address(this),
            type(VestingToken).creationCode,
            abi.encode(
                token, owner, beneficiary, amount, vestingStartTime, vestingPeriod, cliffPeriod
            )
        );

        RadicleToken(token).approve(vestAddress, uint(-1));
        VestingToken vest = new VestingToken{salt: salt}(
            token, owner, beneficiary, amount, vestingStartTime, vestingPeriod, cliffPeriod
        );

        return vest;
    }

    function asBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function namehash(string[] memory domain) internal pure returns (bytes32) {
        if (domain.length == 0) {
            return bytes32(uint(0));
        }
        if (domain.length == 1) {
            return keccak256(abi.encodePacked(bytes32(0), keccak256(bytes(domain[0]))));
        }
        else {
            bytes memory label = bytes(domain[0]);
            string[] memory remainder = new string[](domain.length - 1);
            for (uint i = 1; i < domain.length; i++) {
                remainder[i - 1] = domain[i];
            }
            return keccak256(abi.encodePacked(namehash(remainder), keccak256(label)));
        }
    }

    function namehash(string[1] memory domain) internal pure returns (bytes32) {
        string[] memory dyn = new string[](1);
        dyn[0] = domain[0];
        return namehash(dyn);
    }
    function namehash(string[2] memory domain) internal pure returns (bytes32) {
        string[] memory dyn = new string[](domain.length);
        for (uint i; i < domain.length; i++) {
            dyn[i] = domain[i];
        }
        return namehash(dyn);
    }
    function namehash(string[3] memory domain) internal pure returns (bytes32) {
        string[] memory dyn = new string[](domain.length);
        for (uint i; i < domain.length; i++) {
            dyn[i] = domain[i];
        }
        return namehash(dyn);
    }
    function namehash(string[4] memory domain) internal pure returns (bytes32) {
        string[] memory dyn = new string[](domain.length);
        for (uint i; i < domain.length; i++) {
            dyn[i] = domain[i];
        }
        return namehash(dyn);
    }
    function namehash(string[5] memory domain) internal pure returns (bytes32) {
        string[] memory dyn = new string[](domain.length);
        for (uint i; i < domain.length; i++) {
            dyn[i] = domain[i];
        }
        return namehash(dyn);
    }
}
