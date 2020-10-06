// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.6.2;

/// @notice Funding pool contract. Automatically sends funds to a configurable set of receivers.
///
/// The contract has 2 types of users: the senders and the receivers.
///
/// A sender has some funds and a set of addresses of receivers, to whom he wants to send funds.
/// In order to send there are 3 conditions, which must be fulfilled:
///
/// 1. There must be funds on his account in this contract.
///    They can be added with `topUp` and removed with `withdraw`.
/// 2. Total amount sent to the receivers on each block must be set to a non-zero value.
///    This is done with `setAmountPerBlock`.
/// 3. A set of receivers must be non-empty.
///    Receivers can be added, removed and updated with `setReceiver`.
///    Each receiver has a weight, which is used to calculate how the total sent amount is split.
///
/// Each of these functions can be called in any order and at any time, they have immediate effects.
/// When all of these conditions are fulfilled, on each block the configured amount is being sent.
/// It's extracted from the `withdraw`able balance and transferred to the receivers.
/// The process continues automatically until the sender's balance is empty.
///
/// The receiver has an account, from which he can `collect` funds sent by the senders.
/// The available amount is updated every `cycleBlocks` blocks,
/// so recently sent funds may not be `collect`able immediately.
/// `cycleBlocks` is a constant configured when the pool is deployed.
///
/// A single address can be used both as a sender and as a receiver.
/// It will have 2 balances in the contract, one with funds being sent and one with received,
/// but with no connection between them and no shared configuration.
/// In order to send received funds, they must be first `collect`ed and then `topUp`ped
/// if they are to be sent through the contract.
///
/// The concept of something happening periodically, e.g. every block or every `cycleBlocks` are
/// only high-level abstractions for the user, Ethereum isn't really capable of scheduling work.
/// The actual implementation emulates that behavior by calculating the results of the scheduled
/// events based on how many blocks have been mined and only when a user needs their outcomes.
contract Pool {
    using ReceiverWeightsImpl for mapping(address => ReceiverWeight);

    /// @notice On every block `B`, which is a multiple of `cycleBlocks`, the receivers
    /// gain access to funds collected on all blocks from `B - cycleBlocks` to `B - 1`.
    uint64 public immutable cycleBlocks;
    /// @notice Block number at which all funding periods must be finished
    uint64 internal constant MAX_BLOCK_NUMBER = type(uint64).max - 2;
    /// @notice Maximum sum of all receiver weights of a single sender.
    /// Limits loss of per-block funding accuracy, they are always multiples of weights sum.
    uint32 public constant SENDER_WEIGHTS_SUM_MAX = 1000;
    /// @notice Maximum number of receivers of a single sender.
    /// Limits costs of changes in sender's configuration.
    uint32 public constant SENDER_WEIGHTS_COUNT_MAX = 100;

    struct Sender {
        /// @notice Block number at which the funding period has started
        uint64 startBlock;
        /// @notice The amount available when the funding period has started
        uint192 startBalance;
        // --- SLOT BOUNDARY
        /// @notice The target amount sent on each block.
        /// The actual amount is rounded down to the closes multiple of `weightSum`.
        uint192 amtPerBlock;
        /// @notice The total weight of all the receivers
        uint32 weightSum;
        /// @notice The number of the receivers
        uint32 weightCount;
        // --- SLOT BOUNDARY
        /// @notice The mapping of all the receivers to their weights, iterable
        mapping(address => ReceiverWeight) receiverWeights;
    }

    struct Receiver {
        /// @notice The next block to be collected
        uint64 nextCollectedCycle;
        /// @notice The amount of funds received for the last collected cycle
        uint192 lastFundsPerCycle;
        // --- SLOT BOUNDARY
        /// @notice The changes of collected amounts on specific cycle.
        /// The keys are cycles, each cycle becomes collectable on block `C * cycleBlocks`
        mapping(uint64 => int256) amtDeltas;
    }

    /// @notice Details about all the senders, the key is the owner's address
    mapping(address => Sender) internal senders;
    /// @notice Details about all the receivers, the key is the owner's address
    mapping(address => Receiver) internal receivers;

    /// @param _cycleBlocks The length of cycleBlocks to be used in the contract instance.
    /// Low values make funds more available by shortening the average duration of funds being
    /// frozen between being taken from senders' balances and being collectable by the receiver.
    /// High values make collecting cheaper by making it process less cycles for a given time range.
    constructor(uint64 _cycleBlocks) public {
        cycleBlocks = _cycleBlocks;
    }

    /// @notice Returns amount of received funds available for collection
    /// by the sender of the message
    /// @return collected The available amount
    function collectable() public view returns (uint256) {
        Receiver storage receiver = receivers[msg.sender];
        uint64 collectedCycle = receiver.nextCollectedCycle;
        if (collectedCycle == 0) return 0;
        uint256 collected = 0;
        int256 lastFundsPerCycle = receiver.lastFundsPerCycle;
        uint256 currFinishedCycle = block.number / cycleBlocks;
        for (; collectedCycle <= currFinishedCycle; collectedCycle++) {
            lastFundsPerCycle += receiver.amtDeltas[collectedCycle];
            collected += uint256(lastFundsPerCycle);
        }
        return collected;
    }

    /// @notice Collects all received funds available for collection
    /// by a sender of the message and sends them to that sender
    function collect() public {
        Receiver storage receiver = receivers[msg.sender];
        uint64 collectedCycle = receiver.nextCollectedCycle;
        if (collectedCycle == 0) return;
        uint256 currFinishedCycle = block.number / cycleBlocks;
        if (collectedCycle > currFinishedCycle) return;
        uint256 collected = 0;
        int256 lastFundsPerCycle = receiver.lastFundsPerCycle;
        for (; collectedCycle <= currFinishedCycle; collectedCycle++) {
            int256 delta = receiver.amtDeltas[collectedCycle];
            if (delta != 0) {
                delete receiver.amtDeltas[collectedCycle];
                lastFundsPerCycle += delta;
            }
            collected += uint256(lastFundsPerCycle);
        }
        receiver.lastFundsPerCycle = uint192(lastFundsPerCycle);
        receiver.nextCollectedCycle = collectedCycle;
        if (collected > 0) msg.sender.transfer(collected);
    }

    /// @notice Tops up the sender balance of a sender of the message with the amount in the message
    function topUp() public payable suspendPayments {
        senders[msg.sender].startBalance += uint192(msg.value);
    }

    /// @notice Returns amount of unsent funds available for withdrawal by the sender of the message
    /// @return balance The available balance
    function withdrawable() public view returns (uint256) {
        Sender storage sender = senders[msg.sender];
        // Hasn't been sending anything
        if (sender.weightSum == 0 || sender.amtPerBlock < sender.weightSum) {
            return sender.startBalance;
        }
        uint256 amtPerWeight = sender.amtPerBlock / sender.weightSum;
        uint256 amtPerBlock = amtPerWeight * sender.weightSum;
        uint256 endBlock = sender.startBlock + sender.startBalance / amtPerBlock;
        // The funding period has run out
        if (endBlock <= block.number) {
            return sender.startBalance % amtPerBlock;
        }
        return sender.startBalance - (block.number - sender.startBlock) * amtPerBlock;
    }

    /// @notice Withdraws unsent funds of the sender of the message and sends them to that sender
    /// @param amount The amount to be withdrawn, must not be higher than available funds
    function withdraw(uint256 amount) public suspendPayments {
        uint192 startBalance = senders[msg.sender].startBalance;
        require(amount <= startBalance, "Not enough funds in the sender account");
        senders[msg.sender].startBalance = startBalance - uint192(amount);
        msg.sender.transfer(amount);
    }

    /// @notice Sets the target amount sent on every block from the sender of the message.
    /// On every block this amount is rounded down to the closest multiple of the sum of the weights
    /// of the receivers and split between all sender's receivers proportionally to their weights.
    /// Each receiver then receives their part from the sender's balance.
    /// If set to zero, stops funding.
    /// @param amount The target per-block amount
    function setAmountPerBlock(uint256 amount) public suspendPayments {
        require(type(uint192).max >= amount, "Amount too high");
        senders[msg.sender].amtPerBlock = uint192(amount);
    }

    /// @notice Sets the weight of a receiver of the sender of the message.
    /// The weight regulates the share of the amount being sent on every block in relation to
    /// other sender's receivers.
    /// Setting a non-zero weight for a new receiver, added it to the list of sender's receivers.
    /// Setting the zero weight for a receiver, removes it from the list of sender's receivers.
    /// @param receiver The address of the receiver
    /// @param weight The weight of the receiver
    function setReceiver(address receiver, uint32 weight) public suspendPayments {
        Sender storage sender = senders[msg.sender];
        uint32 oldWeight = sender.receiverWeights.setWeight(receiver, weight);
        sender.weightSum -= oldWeight;
        sender.weightSum += weight;
        require(sender.weightSum <= SENDER_WEIGHTS_SUM_MAX, "Too much total receivers weight");
        if (weight != 0 && oldWeight == 0) {
            sender.weightCount++;
            require(sender.weightSum <= SENDER_WEIGHTS_COUNT_MAX, "Too many receivers");
        } else if (weight == 0 && oldWeight != 0) {
            sender.weightCount--;
        }
    }

    /// @notice Stops payments of `msg.sender` for the duration of the modified function.
    /// This removes and then restores any effects of the sender on all of its receivers' futures.
    /// It allows the function to safely modify any properties of the sender
    /// without having to updating the state of its receivers.
    modifier suspendPayments {
        stopPayments();
        _;
        startPayments();
    }

    /// @notice Stops the sender's payments on the current block
    function stopPayments() internal {
        uint64 blockNumber = uint64(block.number);
        Sender storage sender = senders[msg.sender];
        // Hasn't been sending anything
        if (sender.weightSum == 0 || sender.amtPerBlock < sender.weightSum) return;
        uint192 amtPerWeight = sender.amtPerBlock / sender.weightSum;
        uint192 amtPerBlock = amtPerWeight * sender.weightSum;
        uint256 endBlockUncapped = sender.startBlock + uint256(sender.startBalance / amtPerBlock);
        uint64 endBlock = endBlockUncapped > MAX_BLOCK_NUMBER
            ? MAX_BLOCK_NUMBER
            : uint64(endBlockUncapped);
        // The funding period has run out
        if (endBlock <= blockNumber) {
            sender.startBalance %= amtPerBlock;
            return;
        }
        sender.startBalance -= (blockNumber - sender.startBlock) * amtPerBlock;
        setDeltasFromNow(-int256(amtPerWeight), endBlock);
    }

    /// @notice Starts the sender's payments from the current block
    function startPayments() internal {
        uint64 blockNumber = uint64(block.number);
        Sender storage sender = senders[msg.sender];
        // Won't be sending anything
        if (sender.weightSum == 0 || sender.amtPerBlock < sender.weightSum) return;
        uint192 amtPerWeight = sender.amtPerBlock / sender.weightSum;
        uint192 amtPerBlock = amtPerWeight * sender.weightSum;
        // Won't be sending anything
        if (sender.startBalance < amtPerBlock) return;
        sender.startBlock = blockNumber;
        uint256 endBlockUncapped = blockNumber + uint256(sender.startBalance / amtPerBlock);
        uint64 endBlock = endBlockUncapped > MAX_BLOCK_NUMBER
            ? MAX_BLOCK_NUMBER
            : uint64(endBlockUncapped);
        setDeltasFromNow(int256(amtPerWeight), endBlock);
    }

    /// @notice Sets deltas to all sender's receivers from current block to endBlock
    /// proportionally to their weights
    /// @param amtPerWeightPerBlockDelta Amount of per-block delta applied per receiver weight
    /// @param blockEnd The block number from which the delta stops taking effect
    function setDeltasFromNow(int256 amtPerWeightPerBlockDelta, uint64 blockEnd) internal {
        uint64 blockNumber = uint64(block.number);
        Sender storage sender = senders[msg.sender];
        // Iterating over receivers, see `ReceiverWeights` for details
        address receiverAddr = ReceiverWeightsImpl.ADDR_ROOT;
        while (true) {
            uint32 weight = 0;
            (receiverAddr, weight) = sender.receiverWeights.nextWeight(receiverAddr);
            if (weight == 0) break;
            Receiver storage receiver = receivers[receiverAddr];
            // The receiver was never used, initialize it
            if (amtPerWeightPerBlockDelta > 0 && receiver.nextCollectedCycle == 0)
                receiver.nextCollectedCycle = blockNumber / cycleBlocks + 1;
            int256 perBlockDelta = int256(weight) * amtPerWeightPerBlockDelta;
            // Set delta in a block range from now to `blockEnd`
            setSingleDelta(receiver.amtDeltas, blockNumber, perBlockDelta);
            setSingleDelta(receiver.amtDeltas, blockEnd, -perBlockDelta);
        }
    }

    /// @notice Sets delta of a single receiver on a given block number
    /// @param amtDeltas The deltas of the per-cycle receiving rate
    /// @param blockNumber The block number from which the delta takes effect
    /// @param perBlockDelta Change of the per-block receiving rate
    function setSingleDelta(
        mapping(uint64 => int256) storage amtDeltas,
        uint64 blockNumber,
        int256 perBlockDelta
    ) internal {
        // In order to set a delta on a specific block it must be introduced in two cycles.
        // The cycle delta is split proportionally based on how much the first cycle is affected.
        // The second cycle has the rest of the delta applied, so the update is fully completed.
        uint64 cycle2Blocks = blockNumber % cycleBlocks;
        uint64 cycle1Blocks = cycleBlocks - cycle2Blocks;
        uint64 cycle1 = blockNumber / cycleBlocks + 1;
        uint64 cycle2 = cycle1 + 1;
        amtDeltas[cycle1] += cycle1Blocks * perBlockDelta;
        amtDeltas[cycle2] += cycle2Blocks * perBlockDelta;
    }
}

struct ReceiverWeight {
    address next;
    uint32 weight;
}

/// @notice Helper methods for receiver weights list.
/// The list works optimally if after applying a series of changes it's iterated over.
/// The list uses 1 word of storage per receiver with a non-zero weight.
library ReceiverWeightsImpl {
    address internal constant ADDR_ROOT = address(0);
    address internal constant ADDR_UNINITIALIZED = address(0);
    address internal constant ADDR_END = address(1);

    /// @notice Return the next non-zero receiver weight and its address.
    /// Removes all the zeroed items found between the current and the next receivers.
    /// Iterating over the whole list removes all the zeroed items.
    /// @param current The previously returned receiver address or ADDR_ROOT to start iterating
    /// @return next The next receiver address
    /// @return weight The next receiver weight, ADDR_ROOT if the end of the list was reached
    function nextWeight(mapping(address => ReceiverWeight) storage self, address current)
        internal
        returns (address next, uint32 weight)
    {
        next = self[current].next;
        weight = 0;
        if (next != ADDR_END && next != ADDR_UNINITIALIZED) {
            weight = self[next].weight;
            // remove elements being zero
            if (weight == 0) {
                do {
                    address newNext = self[next].next;
                    // Somehow it's ~1500 gas cheaper than `delete self[next]`
                    self[next].next = ADDR_UNINITIALIZED;
                    next = newNext;
                    if (next == ADDR_END) break;
                    weight = self[next].weight;
                } while (weight == 0);
                // link the previous non-zero element with the next non-zero element
                // or ADDR_END if it became the last element on the list
                self[current].next = next;
            }
        }
    }

    /// @notice Get weight for a specific receiver
    /// @param receiver The receiver to get weight
    /// @return weight The receinver weight
    function getWeight(mapping(address => ReceiverWeight) storage self, address receiver)
        internal
        view
        returns (uint32 weight)
    {
        weight = self[receiver].weight;
    }

    /// @notice Set weight for a specific receiver
    /// @param receiver The receiver to set weight
    /// @param weight The weight to set
    /// @return previousWeight The previously set weight, may be zero
    function setWeight(
        mapping(address => ReceiverWeight) storage self,
        address receiver,
        uint32 weight
    ) internal returns (uint32 previousWeight) {
        previousWeight = self[receiver].weight;
        self[receiver].weight = weight;
        // Item not attached to the list
        if (self[receiver].next == ADDR_UNINITIALIZED) {
            address rootNext = self[ADDR_ROOT].next;
            self[ADDR_ROOT].next = receiver;
            // The first item ever added to the list, root item not initialized yet
            if (rootNext == ADDR_UNINITIALIZED) rootNext = ADDR_END;
            self[receiver].next = rootNext;
        }
    }
}