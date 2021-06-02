// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./NonReentrancy.sol";

import "./interfaces/IGuarantor.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";
import "./interfaces/IStaking.sol";

// Owned by Timelock, and Timelock is owned by GovernerAlpha
contract CommitteeAlpha is Ownable, NonReentrancy {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IRegistry public registry;

    address[] public members;
    mapping(address => uint256) public memberIndexPlusOne;  // index + 1

    uint256 public feeToRequestPayout = 20e18;
    uint256 public maximumRequestDuration = 3 days;

    struct PayoutStartRequest {
        uint256 time;
        uint16 assetIndex;
        address requester;
        bool executed;
        uint256 voteCount;
        mapping(address => bool) votes;
    }

    PayoutStartRequest[] public payoutStartRequests;

    struct PayoutAmountRequest {
        address toAddress;
        uint256 sellerAmount;
        uint256 guarantorAmount;
        uint256 stakingAmount;
        bool executed;
        uint256 voteCount;
        mapping(address => bool) votes;
    }

    // assetIndex => payoutId => PayoutAmountRequest
    mapping(uint16 => mapping(uint256 => PayoutAmountRequest)) public payoutAmountRequestMap;

    uint256 public commiteeVoteThreshod = 4;

    constructor () public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    function setFeeToRequestPayout(uint256 fee_) external onlyOwner {
        feeToRequestPayout = fee_;
    }

    function setMaximumRequestDuration(uint256 duration_) external onlyOwner {
        maximumRequestDuration = duration_;
    }

    function setCommiteeVoteThreshod(uint256 threshold_) external onlyOwner {
        commiteeVoteThreshod = threshold_;
    }

    function addMember(address who_) external onlyOwner {
        require(memberIndexPlusOne[who_] == 0, "Already a member");
        members.push(who_);
        memberIndexPlusOne[who_] = members.length;
    }

    function removeMember(address who_) external onlyOwner {
        uint256 indexPlusOne = memberIndexPlusOne[who_];
        require(indexPlusOne > 0, "Invalid address / not a member");
        require(indexPlusOne <= members.length, "Out of range");
        if (indexPlusOne < members.length) {
            members[indexPlusOne.sub(1)] = members[members.length.sub(1)];
            memberIndexPlusOne[members[indexPlusOne.sub(1)]] = indexPlusOne;
            memberIndexPlusOne[who_] = 0;
        }

        members.pop();
    }

    function isMember(address who_) public view returns(bool) {
        return memberIndexPlusOne[who_] > 0;
    }

    function isPayoutStartRequestExpired(uint256 requestIndex_) public view returns(bool) {
        return now >= payoutStartRequests[requestIndex_].time + maximumRequestDuration;
    }

    // Step 1 (request), anyone pays USDC to request payout.
    function requestPayoutStart(uint16 assetIndex_) external lock {
        IERC20(registry.baseToken()).safeTransferFrom(
            msg.sender, registry.platform(), feeToRequestPayout);

        PayoutStartRequest memory request;
        request.time = now;
        request.assetIndex = assetIndex_;
        request.requester = msg.sender;
        request.executed = false;
        request.voteCount = 0;
        payoutStartRequests.push(request);
    }

    // Step 1 (vote & execute), called by commitee members directly.
    // The last caller needs to provide a correct payoutId (not hard figure it out),
    // otherwise it reverts.
    function confirmPayoutStartRequest(uint256 requestIndex_, uint256 payoutId_) external {
        PayoutStartRequest storage request = payoutStartRequests[requestIndex_];

        require(isMember(msg.sender), "Requires member");
        require(!request.votes[msg.sender], "Already voted");
        require(!request.executed, "Already executed");
        require(!isPayoutStartRequestExpired(requestIndex_), "Already expired");

        request.votes[msg.sender] = true;
        request.voteCount = request.voteCount.add(1);

        if (request.voteCount >= commiteeVoteThreshod) {
            ISeller(registry.seller()).startPayout(request.assetIndex, payoutId_);
            IGuarantor(registry.guarantor()).startPayout(request.assetIndex, payoutId_);
            IStaking(registry.staking()).startPayout(payoutId_);
            request.executed = true;
        }
    }

    // Step 2 relies on the DAO, TIDAL stakers propose (the Step 3 request) and vote
    // in GovernerAlpha.

    // Step 3 (request), called by timelock (GovernerAlpha).
    function requestPayoutAmount(
        uint16 assetIndex_,
        uint256 payoutId_,
        address toAddress_,
        uint256 sellerAmount_,
        uint256 guarantorAmount_,
        uint256 stakingAmount_
    ) external onlyOwner {
        PayoutAmountRequest memory request;
        request.toAddress = toAddress_;
        request.sellerAmount = sellerAmount_;
        request.guarantorAmount = guarantorAmount_;
        request.stakingAmount = stakingAmount_;
        request.executed = false;
        request.voteCount = 0;
        payoutAmountRequestMap[assetIndex_][payoutId_] = request;
    }

    // Step 3 (vote & execute), called by commitee members directly.
    function confirmPayoutAmountRequest(uint16 assetIndex_, uint256 payoutId_) external {
        PayoutAmountRequest storage request = payoutAmountRequestMap[assetIndex_][payoutId_];

        require(isMember(msg.sender), "Requires member");
        require(!request.votes[msg.sender], "Already voted");
        require(!request.executed, "Already executed");

        request.votes[msg.sender] = true;
        request.voteCount = request.voteCount.add(1);

        if (request.voteCount >= commiteeVoteThreshod) {
            ISeller(registry.seller()).setPayout(
                assetIndex_, payoutId_, request.toAddress, request.sellerAmount);
            IGuarantor(registry.guarantor()).setPayout(
                assetIndex_, payoutId_, request.toAddress, request.guarantorAmount);
            IStaking(registry.staking()).setPayout(
                payoutId_, request.toAddress, request.stakingAmount);
            request.executed = true;
        }
    }
}
