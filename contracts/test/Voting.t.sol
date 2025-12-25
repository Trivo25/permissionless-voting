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
            uint32 noCount
        ) = voting.proposals(proposalId);

        assertEq(creator, address(this));
        assertEq(pid, uint32(proposalId));
        assertEq(commitDeadline, deadline);
        assertEq(commitmentsDigest, bytes32(0));
        assertEq(tallied, false);
        assertEq(yesCount, 0);
        assertEq(noCount, 0);
    }

    function test_createProposal_past_deadline() public {
        uint64 deadline = uint64(block.timestamp - 1 seconds);
        vm.expectRevert("cannot create proposals with deadlines in the past");
        voting.createProposal(deadline);
    }
}
