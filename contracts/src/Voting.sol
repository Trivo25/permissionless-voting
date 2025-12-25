pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";

struct Proposal {
    address creator;
    uint32 proposalId;
    uint64 commitDeadline; // timestamp
    bytes32 commitmentsDigest; // accumulator over (voter, commitment) in commit order
    bool tallied;
    uint32 yesCount;
    uint32 noCount;
    uint32 votesCount;
}

contract Voting {
    // tracking all proposals
    uint256 public proposalCount;

    // mapping of proposalID to proposal
    mapping(uint256 => Proposal) public proposals;

    constructor() {
        proposalCount = 0;
    }

    function createProposal(uint64 proposalDeadline) external returns (uint256 proposalId) {
        require(proposalDeadline > block.timestamp, "cannot create proposals with deadlines in the past");
        proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            creator: msg.sender,
            proposalId: uint32(proposalId),
            commitDeadline: proposalDeadline,
            commitmentsDigest: keccak256(abi.encodePacked("proposal", block.chainid, address(this), proposalId)),
            tallied: false,
            yesCount: 0,
            noCount: 0,
            votesCount: 0
        });

        return proposalId;
    }

    function castVote(uint256 proposalId, bytes32 commitment) external {
        Proposal storage p = proposals[proposalId];

        require(p.creator != address(0), "proposal does not exist");
        require(block.timestamp < p.commitDeadline, "commit phase over");

        // update accumulator, digest = H(prevDigest || commitment)
        p.commitmentsDigest = keccak256(abi.encodePacked(p.commitmentsDigest, commitment));
        p.votesCount += 1;
        proposals[proposalId] = p;
    }

    function requestTally(uint256 proposalId) external {}
}
