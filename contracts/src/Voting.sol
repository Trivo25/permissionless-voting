pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";

/* import {ImageID} from "./ImageID.sol"; // auto-generated contract after running `cargo build`.
 */
struct Proposal {
    address creator;
    uint32 proposalId;
    uint64 commitDeadline; // timestamp
    bytes32 commitmentsDigest; // accumulator over (voter, commitment) in commit order
    bool tallied;
    uint32 yesCount;
    uint32 noCount;
}

contract Voting {
    // tracking all proposals
    uint256 public proposalCount;

    // mapping of proposalID to proposal
    mapping(uint256 => Proposal) public proposals;

    constructor() {
        proposalCount = 0;
    }

    function createProposal(uint64 proposalDeadline) external returns (uint256 proposalId) {}

    function commitVote(uint256 proposalId, bytes32 commitment) external {}

    function requestTally(uint256 proposalId) external {}
}
