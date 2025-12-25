pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Voting} from "../src/Voting.sol";
import "openzeppelin/contracts/utils/Strings.sol";

contract VotingTester is Test {
    Voting public voting;

    function setUp() public {
        voting = new Voting();
        assertEq(voting.proposalCount(), 0);
    }

    function test_createProposal() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 proposalId = voting.createProposal(deadline);
        assertEq(proposalId, 0);
        assertEq(voting.proposalCount(), 1);
    }

    function test_createProposal_past_deadline() public {
        uint64 deadline = uint64(block.timestamp - 1 seconds);
        vm.expectRevert("cannot create proposals with deadlines in the past");
        voting.createProposal(deadline);
    }
}
