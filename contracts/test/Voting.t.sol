pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Voting, VotePublicOutput} from "../src/Voting.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {Receipt as RiscZeroReceipt} from "risc0/IRiscZeroVerifier.sol";
import {ImageID} from "../src/ImageID.sol";

contract VotingTester is Test {
    Voting public voting;
    RiscZeroMockVerifier public verifier;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address florian = makeAddr("florian");

    function setUp() public {
        verifier = new RiscZeroMockVerifier(0);
        voting = new Voting(verifier);
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
        assertEq(commitmentsDigest, keccak256(abi.encode(proposalId)));
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

    function test_castVote_reverts_if_proposal_missing() public {
        vm.prank(alice);
        vm.expectRevert("proposal does not exist");
        voting.castVote(999, keccak256("x"));
    }

    function test_castVote_reverts_after_deadline() public {
        uint64 deadline = uint64(block.timestamp + 10);
        uint256 proposalId = voting.createProposal(deadline);

        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert("commit phase over");
        voting.castVote(proposalId, keccak256("x"));
    }

    function test_settleTallyManually_settles_tally() public {
        uint256 proposalId = voting.createProposal(uint64(block.timestamp + 1 days));
        (,,, bytes32 commitmentsDigest,,,,) = voting.proposals(proposalId);
        bytes memory journal = abi.encode(
            VotePublicOutput({proposalId: proposalId, yes: 42, no: 17, commitmentsDigest: commitmentsDigest})
        );

        RiscZeroReceipt memory receipt = verifier.mockProve(ImageID.VOTING_TALLY_ID, sha256(journal));

        voting.settleTallyManually(journal, receipt.seal);

        (bool tallied, uint32 yesCount, uint32 noCount,) = voting.checkProposalTallyState(proposalId);
        assertEq(tallied, true);
        assertEq(yesCount, 42);
        assertEq(noCount, 17);
    }

    function test_handleProof_emits_event() public {
        uint256 proposalId = voting.createProposal(uint64(block.timestamp + 1 days));
        (,,, bytes32 commitmentsDigest,,,,) = voting.proposals(proposalId);

        VotePublicOutput memory publicOutput =
            VotePublicOutput({proposalId: proposalId, commitmentsDigest: commitmentsDigest, yes: 10, no: 5});
        bytes memory journal = abi.encode(publicOutput);

        RiscZeroReceipt memory receipt = verifier.mockProve(ImageID.VOTING_TALLY_ID, sha256(journal));

        vm.expectEmit(false, false, false, true, address(voting));
        emit Voting.Proof(publicOutput);
        voting.handleProof(ImageID.VOTING_TALLY_ID, journal, receipt.seal);
    }
}
