pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Voting} from "../src/Voting.sol";
import "openzeppelin/contracts/utils/Strings.sol";

contract VotingTester is Test {
    Voting public voting;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address florian = makeAddr("florian");

    function setUp() public {
        voting = new Voting();
        assertEq(voting.proposalCount(), 0);
    }

    function test_createProposal() public {
        uint64 deadline = uint64(block.timestamp + 1 days);

        vm.prank(florian);

        uint256 proposalId = voting.createProposal(deadline);
        assertEq(proposalId, 0);
        assertEq(voting.proposalCount(), 1);

        (
            address creator,
            uint32 pid,
            uint64 commitDeadline,
            bytes32 commitmentsDigest,
            bool tallied,
            uint32 yesCount,
            uint32 noCount,
            uint32 votesCount
        ) = voting.proposals(proposalId);

        assertEq(creator, address(florian));
        assertEq(pid, uint32(proposalId));
        assertEq(commitDeadline, deadline);
        assertEq(commitmentsDigest, keccak256(abi.encode("proposal", block.chainid, address(voting), proposalId)));
        assertEq(tallied, false);
        assertEq(yesCount, 0);
        assertEq(noCount, 0);
        assertEq(votesCount, 0);
    }

    function test_createProposal_past_deadline() public {
        uint64 deadline = uint64(block.timestamp - 1 seconds);
        vm.expectRevert("cannot create proposals with deadlines in the past");
        voting.createProposal(deadline);
    }

    function test_castVote_updates_digest() public {
        uint256 proposalId = voting.createProposal(uint64(block.timestamp + 1 days));
        (,,, bytes32 originalDigest,,,,) = voting.proposals(proposalId);

        // cast vote #1
        vm.prank(alice);

        // the commitment of the vote is H(address || choice || proposalID)
        bytes32 aliceCommitment = keccak256(abi.encode(alice, true, proposalId));
        voting.castVote(proposalId, aliceCommitment);

        (,,, bytes32 digestAfterAlice,,,, uint32 votesCountAfterAlice) = voting.proposals(proposalId);
        console2.logBytes32(digestAfterAlice);
        bytes32 expectedAfterAlice = keccak256(abi.encode(originalDigest, aliceCommitment));
        assertEq(digestAfterAlice, expectedAfterAlice);
        assertEq(votesCountAfterAlice, 1);

        // cast vote #2
        vm.prank(bob);
        bytes32 bobCommitment = keccak256(abi.encode(bob, true, proposalId));
        voting.castVote(proposalId, bobCommitment);

        (,,, bytes32 digestAfterBob,,,, uint32 votesCountAfterBob) = voting.proposals(proposalId);
        console2.logBytes32(digestAfterBob);
        bytes32 expectedAfterBob = keccak256(abi.encode(expectedAfterAlice, bobCommitment));
        assertEq(digestAfterBob, expectedAfterBob);
        assertEq(votesCountAfterBob, 2);
    }
}
