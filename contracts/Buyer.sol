// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/ISeller.sol";
import "./interfaces/IPolicy.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The base of percentage.
    uint256 constant PERCENTAGE_BASE = 100;

    // The base of premium rate and accWeeklyCost
    uint256 constant PREMIUM_BASE = 1e6;

    IERC20 public baseToken;  // By default it's USDC
    IAssetManager public assetManager;
    IGuarantor public guarantor;
    ISeller public seller;
    uint256 public guarantorPercentage = 10;  // 10%

    struct UserInfo {
        uint256 balance;
        uint256 weekBegin;  // The week the coverage begin
        uint256 weekEnd;  // The week the coverage end
        uint256 weekUpdated;  // The week that balance was updated
    }

    mapping(address => UserInfo) public userInfoMap;

    // user => assetIndex => amount
    mapping(address => mapping(uint256 => uint256)) public override currentSubscription;

    // user => assetIndex => amount
    mapping(address => mapping(uint256 => uint256)) public override futureSubscription;

    // week => assetIndex => total
    mapping(uint256 => mapping(uint256 => uint256)) public weeklyTotalSubscription;

    // assetIndex => total
    mapping(uint256 => uint256) public override premiumForGuarantor;

    // category => total
    mapping(uint8 => uint256) public override premiumForSeller;

    uint256 public override weekToUpdate;

    constructor () public { }

    function setBaseToken(IERC20 baseToken_) public onlyOwner {
        baseToken = baseToken_;
    }

    function setAssetManager(IAssetManager assetManager_) public onlyOwner {
        assetManager = assetManager_;
    }

    function setSeller(ISeller seller_) public onlyOwner {
        seller = seller_;
    }

    function setGuarantor(IGuarantor guarantor_) public onlyOwner {
        guarantor = guarantor_;
    }

    function setGuarantorPercentage(uint256 percentage_) public onlyOwner {
        require(percentage_ < PERCENTAGE_BASE, "Invalid input");
        guarantorPercentage = percentage_;
    }

    function getPremiumRate(uint8 category_, uint256 week_) public view returns(uint256) {
        if (category_ == 0) {
            return 14000;
        } else if (category_ == 1) {
            return 56000;
        } else {
            return 108000;
        }
    }

    function getCurrentWeek() public view returns(uint256) {
        return now.div(7 days);
    }

    function isUserCovered(address who_) public override view returns(bool) {
        return userInfoMap[who_].weekEnd == getCurrentWeek();
    }

    function getTotalFutureSubscription(address who_) public view returns(uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < assetManager.getAssetLength(); ++i) {
            if (futureSubscription[who_][i] > 0) {
                total = total.add(futureSubscription[who_][i]);
            }
        }

        return total;
    }

    function getBalance(address who_) public view returns(uint256) {
        return userInfoMap[who_].balance;
    }

    // Called every week.
    function beforeUpdate() public {
        uint256 currentWeek = getCurrentWeek();

        require(weekToUpdate < currentWeek, "Already called");

        if (weekToUpdate > 0) {
            uint8 category;

            for (category = 0; category < assetManager.getCategoryLength(); ++category) {
                premiumForSeller[category] = 0;
            }

            uint256 totalForGuarantor = 0;
            uint256 totalForSeller = 0;

            // To preserve last week's data before update buyers.
            for (uint256 index = 0; index < assetManager.getAssetLength(); ++index) {
                category = assetManager.getAssetCategory(index);
                premiumForGuarantor[index] = weeklyTotalSubscription[weekToUpdate][index] * guarantorPercentage / PERCENTAGE_BASE;
                totalForGuarantor = totalForGuarantor.add(premiumForGuarantor[index]);

                uint256 deltaForCategory = weeklyTotalSubscription[weekToUpdate][index] * (PERCENTAGE_BASE - guarantorPercentage) / PERCENTAGE_BASE;
                premiumForSeller[category] = premiumForSeller[category].add(deltaForCategory);
                totalForSeller = totalForSeller.add(deltaForCategory);
            }

            IERC20(baseToken).approve(address(guarantor), totalForGuarantor);
            IERC20(baseToken).approve(address(seller), totalForSeller);
        }

        weekToUpdate = currentWeek;
    }

    // Called for every user every week.
    function update(address who_) public {
        uint256 currentWeek = getCurrentWeek();

        require(currentWeek == weekToUpdate, "Not ready to update");

        uint256 cost = getTotalFutureSubscription(who_);

        if (userInfoMap[who_].balance >= cost) {
            userInfoMap[who_].balance = userInfoMap[who_].balance.sub(cost);

            if (userInfoMap[who_].weekBegin == 0 ||
                    userInfoMap[who_].weekEnd < userInfoMap[who_].weekUpdated) {
                userInfoMap[who_].weekBegin = currentWeek;
            }

            userInfoMap[who_].weekEnd = currentWeek;

            for (uint256 index = 0; index < assetManager.getAssetLength(); ++index) {
                if (futureSubscription[who_][index] > 0) {
                    currentSubscription[who_][index] = futureSubscription[who_][index];
                    weeklyTotalSubscription[currentWeek][index] =
                        weeklyTotalSubscription[currentWeek][index].add(futureSubscription[who_][index]);
                } else if (currentSubscription[who_][index] > 0) {
                    currentSubscription[who_][index] = 0;
                }
            }
        }
        
        userInfoMap[who_].weekUpdated = currentWeek;  // This week.
    }

    // Deposit
    function deposit(uint256 amount_) external {
        update(msg.sender);

        baseToken.safeTransferFrom(msg.sender, address(this), amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.add(amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external {
        update(msg.sender);

        require(userInfoMap[msg.sender].balance > amount_, "not enough balance");
        baseToken.safeTransfer(msg.sender, amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.sub(amount_);
    }

    function subscribe(uint256 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].add(amount_);
    }

    function unsubscribe(uint256 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].sub(amount_);
    }
}
