// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./WeekManaged.sol";

import "./tokens/GovernanceToken.sol";
import "./interfaces/IRegistry.sol";

// This contract is owned by Timelock.
contract Staking is Ownable, GovernanceToken, WeekManaged {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // For improving precision.
    uint256 constant UNIT_PER_SHARE = 1e18;

    // Info of each user.
    struct UserInfo {
        uint256 rewardAmount;
        uint256 rewardDebt; // Reward debt.
    }

    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    // Info of the pool.
    struct PoolInfo {
        uint256 rewardPerBlock;
        uint256 startBlock;
        uint256 endBlock;
        uint256 lastRewardBlock;
        uint256 accRewardPerShare; // Accumulated TIDAL per share, times UNIT_PER_SHARE.
    }

    // Info of the pool.
    PoolInfo public poolInfo;

    // Withdraw request.
    struct WithdrawRequest {
        uint256 time;
        uint256 amount;
        bool executed;
    }

    // who => WithdrawRequest[]
    mapping(address => WithdrawRequest[]) public withdrawRequestMap;

    uint256 public withdrawWaitTime = 14 days;

    IRegistry public registry;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // payoutId => PayoutInfo
    mapping(uint256 => PayoutInfo) public payoutInfo;

    uint256 public payoutId;

    // who => payoutId
    mapping(address => uint256) userPayoutIdMap;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawReady(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);

    constructor () GovernanceToken("Tidal Staking", "TIDAL-STAKING") public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    function set(
        uint256 rewardPerBlock_,
        uint256 startBlock_,
        uint256 endBlock_,
        bool withUpdate_
    ) external onlyOwner {
        if (withUpdate_) {
            updatePool();
        }

        poolInfo.rewardPerBlock = rewardPerBlock_;
        poolInfo.startBlock = startBlock_;
        poolInfo.endBlock = endBlock_;
    }

    // Return reward multiplier over the given _from to _to block.
    function getReward(uint256 from_, uint256 to_)
        public
        view
        returns (uint256)
    {
        if (to_ <= from_) {
            return 0;
        }

        uint256 startBlock = from_ < poolInfo.startBlock ? poolInfo.startBlock : from_;
        uint256 endBlock = to_ < poolInfo.endBlock ? to_ : poolInfo.endBlock;
        return endBlock.sub(startBlock).mul(poolInfo.rewardPerBlock);
    }

    // View function to see pending TIDAL on frontend.
    function pendingReward(address who_)
        external
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[who_];
        uint256 tokenTotal = totalSupply();

        uint256 accRewardPerShare = 0;

        if (block.number > poolInfo.lastRewardBlock && tokenTotal > 0) {
            uint256 reward = getReward(poolInfo.lastRewardBlock, block.number);
            accRewardPerShare = poolInfo.accRewardPerShare.add(
                reward.mul(UNIT_PER_SHARE).div(tokenTotal)
            );
        }

        uint256 userAmount = balanceOf(who_);
        return userAmount.mul(accRewardPerShare).div(
            UNIT_PER_SHARE).sub(user.rewardDebt).add(user.rewardAmount);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        if (block.number <= poolInfo.lastRewardBlock) {
            return;
        }

        uint256 tokenTotal = totalSupply();
        if (tokenTotal == 0) {
            poolInfo.lastRewardBlock = block.number;
            return;
        }

        uint256 reward = getReward(poolInfo.lastRewardBlock, block.number);

        poolInfo.accRewardPerShare = poolInfo.accRewardPerShare.add(
            reward.mul(UNIT_PER_SHARE).div(tokenTotal)
        );

        poolInfo.lastRewardBlock = block.number;
    }

    function deposit(uint256 amount_) external {
        require(!hasPendingPayout(), "Has pending payout");

        UserInfo storage user = userInfo[msg.sender];
        updatePool();

        uint256 userAmount = balanceOf(msg.sender);
        if (userAmount > 0) {
            uint256 pending = userAmount.mul(poolInfo.accRewardPerShare).div(
                UNIT_PER_SHARE).sub(user.rewardDebt);

            user.rewardAmount = user.rewardAmount.add(pending);
        }

        IERC20(registry.tidalToken()).transferFrom(
            msg.sender,
            address(this),
            amount_
        );

        GovernanceToken._mint(msg.sender, amount_);
        user.rewardDebt = userAmount.add(amount_).mul(poolInfo.accRewardPerShare).div(UNIT_PER_SHARE);

        emit Deposit(msg.sender, amount_);
    }

    function withdraw(uint256 amount_) external {
        require(!hasPendingPayout(), "Has pending payout");

        uint256 userAmount = balanceOf(msg.sender);
        require(userAmount >= amount_, "Not enough amount");

        withdrawRequestMap[msg.sender].push(WithdrawRequest({
            time: getCurrentWeek(),
            amount: amount_,
            executed: false
        }));

        emit Withdraw(msg.sender, amount_);
    }

    function withdrawReady(address who_, uint256 index_) external {
        WithdrawRequest storage request = withdrawRequestMap[who_][index_];

        require(request.time > 0, "Non-existing request");
        require(getCurrentWeek() > request.time.add(withdrawWaitTime), "Not ready yet");
        require(!request.executed, "already executed");

        UserInfo storage user = userInfo[who_];

        uint256 userAmount = balanceOf(who_);
        require(userAmount >= request.amount, "Not enough amount");

        updatePool();

        if (userAmount > 0) {
            uint256 pending = userAmount.mul(poolInfo.accRewardPerShare).div(
                UNIT_PER_SHARE).sub(user.rewardDebt);
            user.rewardAmount = user.rewardAmount.add(pending);
        }

        GovernanceToken._burn(who_, request.amount);
        user.rewardDebt = userAmount.sub(request.amount).mul(poolInfo.accRewardPerShare).div(UNIT_PER_SHARE);

        IERC20(registry.tidalToken()).transfer(address(who_), request.amount);

        request.executed = true;

        emit WithdrawReady(who_, request.amount);
    }


    // claim all reward.
    function claim() external {
        UserInfo storage user = userInfo[msg.sender];

        updatePool();

        uint256 userAmount = balanceOf(msg.sender);
        uint256 pending = userAmount.mul(poolInfo.accRewardPerShare).div(
            UNIT_PER_SHARE).sub(user.rewardDebt);
        uint256 rewardTotal = user.rewardAmount.add(pending);

        IERC20(registry.tidalToken()).transfer(msg.sender, rewardTotal);

        user.rewardAmount = 0;
        user.rewardDebt = userAmount.mul(poolInfo.accRewardPerShare).div(UNIT_PER_SHARE);

        emit Claim(msg.sender, rewardTotal);
    }

    function isAssetLocked(address who_) public view returns(bool) {
        return payoutId > 0 && !payoutInfo[payoutId].finished && userPayoutIdMap[who_] < payoutId;
    }

    function hasPendingPayout() public view returns(bool) {
        return payoutId > 0 && !payoutInfo[payoutId].finished;
    }

    function startPayout(uint256 payoutId_) external onlyOwner {
        require(payoutId_ == payoutId + 1, "payoutId should be increasing");
        payoutId = payoutId_;
    }

    function setPayout(uint256 payoutId_, address toAddress_, uint256 total_) external onlyOwner {
        require(payoutId_ == payoutId, "payoutId should be started");
        require(payoutInfo[payoutId_].total == 0, "already set");

        uint256 tokenTotal = totalSupply();

        require(total_ <= tokenTotal, "More than token total");

        payoutInfo[payoutId_].toAddress = toAddress_;
        payoutInfo[payoutId_].total = total_;
        payoutInfo[payoutId_].unitPerShare = total_.mul(UNIT_PER_SHARE).div(tokenTotal);
        payoutInfo[payoutId_].paid = 0;
        payoutInfo[payoutId_].finished = false;
    }

    function doPayout(address who_) external {
        UserInfo storage user = userInfo[who_];
        updatePool();

        uint256 userAmount = balanceOf(who_);
        if (userAmount > 0) {
            uint256 pending = userAmount.mul(poolInfo.accRewardPerShare).div(
                UNIT_PER_SHARE).sub(user.rewardDebt);
            user.rewardAmount = user.rewardAmount.add(pending);
        }

        for (uint256 payoutId_ = userPayoutIdMap[who_] + 1; payoutId_ <= payoutId; ++payoutId_) {
            userPayoutIdMap[who_] = payoutId_;

            if (payoutInfo[payoutId_].finished) {
                continue;
            }

            uint256 amountToPay = userAmount.mul(payoutInfo[payoutId_].unitPerShare).div(UNIT_PER_SHARE);
            GovernanceToken._burn(who_, amountToPay);

            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].paid.add(amountToPay);
        }

        userAmount = balanceOf(who_);
        user.rewardDebt = userAmount.mul(poolInfo.accRewardPerShare).div(UNIT_PER_SHARE);
    }

    function finishPayout(uint256 payoutId_) external {
        require(!payoutInfo[payoutId_].finished, "already finished");

        if (payoutInfo[payoutId_].paid < payoutInfo[payoutId_].total) {
            // In case there is still small error, you, the caller please pay for it.
            IERC20(registry.tidalToken()).transferFrom(msg.sender, address(this), payoutInfo[payoutId_].total - payoutInfo[payoutId_].paid);
            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].total;
        }

        IERC20(registry.tidalToken()).transfer(payoutInfo[payoutId_].toAddress, payoutInfo[payoutId_].total);

        payoutInfo[payoutId_].finished = true;
    }

    function _transfer(address sender_, address recipient_, uint256 amount_) internal virtual override {
        require(!hasPendingPayout(), "Has pending payout");

        UserInfo storage fromUser = userInfo[sender_];
        UserInfo storage toUser = userInfo[recipient_];
        updatePool();

        uint256 fromUserAmount = balanceOf(sender_);
        if (fromUserAmount > 0) {
            uint256 fromUserPending = fromUserAmount.mul(poolInfo.accRewardPerShare).div(
                UNIT_PER_SHARE).sub(fromUser.rewardDebt);
            fromUser.rewardAmount = fromUser.rewardAmount.add(fromUserPending);
        }

        uint256 toUserAmount = balanceOf(recipient_);
        if (toUserAmount > 0) {
            uint256 toUserPending = toUserAmount.mul(poolInfo.accRewardPerShare).div(
                UNIT_PER_SHARE).sub(toUser.rewardDebt);
            toUser.rewardAmount = toUser.rewardAmount.add(toUserPending);
        }

        super._transfer(sender_, recipient_, amount_);

        fromUser.rewardDebt = fromUserAmount.sub(amount_).mul(poolInfo.accRewardPerShare).div(UNIT_PER_SHARE);
        toUser.rewardDebt = toUserAmount.sub(amount_).mul(poolInfo.accRewardPerShare).div(UNIT_PER_SHARE);
    }
}
