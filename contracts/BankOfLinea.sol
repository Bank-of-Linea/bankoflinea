// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BankOfLinea
 * @dev A deflationary ERC20 token with reflection and liquidity mechanisms.
 * Tax fees are applied on buy and sell transactions, with portions allocated for reflections, liquidity, and marketing.
 */
contract BankOfLinea is ERC20, Ownable, ReentrancyGuard {
    // Custom errors
    error IndexOutOfBounds();
    error DistributionNotReady();
    error ExcludedFromRewards();
    error NoRewardsAvailable();
    error InvalidAddress();
    error InsufficientBalance();
    error TimelockNotExpired();
    error ETHTransferFailed();

    // Transaction fees
    uint256 public buyFee = 5; // 5% on buy transactions
    uint256 public sellFee = 7; // 7% on sell transactions

    uint256 public TRANSFER_FEE = 2; // 2% fee on all transfers

    // Minimum token balance required to receive ETH rewards
    uint256 public minHoldForRewards = 10_000 * 10 ** decimals();
    // Dynamic rewards fee share (can be updated)
    uint256 public rewardsPercentage = 70; // Default: 70%
    // Maximum transaction and wallet limits (stored in basis points)
    uint256 public maxTransactionBps = 25; // 0.25% in basis points (only for LP interactions)
    uint256 public maxWalletBps = 50; // 0.5% in basis points

    // Marketing wallet address
    address public marketingWallet;

    uint256 public totalEligibleAmount;

    // Total ETH collected for reflections
    uint256 public totalCollected;

    // Excluded addresses from reflection rewards
    mapping(address => bool) public excludedFromRewards;

    // Exempted addresses from fees
    mapping(address => bool) public exemptedFromFees;

    // Reflection rewards per holderss
    mapping(address => uint256) private rewards;

    // Liquidity pools mapping
    mapping(address => bool) public isLiquidityPool;

    // Timestamp of the last distribution
    uint256 private lastDistributed;

    // List of token holders
    address[] private holders;
    mapping(address => uint256) private holderIndex; // store index + 1 (0 means absent)

    // Events
    event ReflectionDistributed(uint256 amount);
    event FeesUpdated(uint256 buyFee, uint256 sellFee);
    event ExclusionUpdated(address account, bool isExcluded);
    event RewardsClaimed(address account, uint256 amount);
    event FeeChangeProposed(uint256 newBuyFee, uint256 newSellFee, uint256 timestamp);
    event ETHWithdrawn(address owner, uint256 amount);
    event LiquidityPoolAdded(address pool, bool status);
    event MinHoldUpdated(uint256 newMinHold);
    event RewardsPercentageUpdated(uint256 newPercentage);
    event MaxTransactionBpsUpdated(uint256 newMaxTransactionBps);
    event MaxWalletBpsUpdated(uint256 newMaxWalletBps);

    // Internal flag to prevent fee application during internal transfers
    bool private inFeeTransfer;

    /**
     * @dev Constructor to initialize the token.
     * @param _marketingWallet Address of the marketing wallet.
     */
    constructor(address _marketingWallet) ERC20("BankOfLinea", "BOL") Ownable(msg.sender) {
        if (_marketingWallet == address(0)) revert InvalidAddress();

        marketingWallet = _marketingWallet;

        // Exclude certain addresses from rewards
        excludedFromRewards[address(this)] = true; // Contract address
        excludedFromRewards[marketingWallet] = true; // Marketing wallet
        exemptedFromFees[address(this)] = true;
        exemptedFromFees[marketingWallet] = true;

        _mint(_marketingWallet, 100_000_000 * 10 ** decimals()); // Mint initial supply to the marketing wallet
    }

    /**
     * @dev Internal function to handle transfers without applying fees.
     * @param sender The address sending tokens.
     * @param recipient The address receiving tokens.
     * @param amount The amount of tokens being transferred.
     */
    function _internalTransfer(address sender, address recipient, uint256 amount) internal {
        inFeeTransfer = true;
        _update(sender, recipient, amount);
        inFeeTransfer = false;
    }

    /**
     * @notice Updates the minimum holding requirement for receiving ETH rewards.
     * @param _minHold The new minimum token balance required.
     */
    function setMinHoldForRewards(uint256 _minHold) external onlyOwner {
        minHoldForRewards = _minHold;
        emit MinHoldUpdated(_minHold);
    }

    /**
     * @notice Updates the rewards percentage for fee distribution.
     * @param _newPercentage The new percentage of the fee to go to rewards (0-100).
     */
    function setRewardsPercentage(uint256 _newPercentage) external onlyOwner {
        require(_newPercentage <= 10000, "Percentage(Basis Points) cannot exceed 10000");
        rewardsPercentage = _newPercentage / 100;
        emit RewardsPercentageUpdated(_newPercentage);
    }

    /**
     * @notice Converts basis points to absolute token values.
     * @param bps The basis points to convert.
     * @return The equivalent token amount.
     */
    function _convertBpsToAmount(uint256 bps) internal view returns (uint256) {
        return (totalSupply() * bps) / 10000;
    }

    /**
     * @notice Updates the max transaction limit (only for LP trades).
     * @param _newMaxTransactionBps The new max transaction limit in basis points.
     */
    function setMaxTransactionBps(uint256 _newMaxTransactionBps) external onlyOwner {
        require(_newMaxTransactionBps <= 10000, "Cannot exceed 100%"); // Safety limit
        maxTransactionBps = _newMaxTransactionBps;
        emit MaxTransactionBpsUpdated(_newMaxTransactionBps);
    }

    /**
     * @notice Updates the max wallet balance limit.
     * @param _newMaxWalletBps The new max wallet balance limit in basis points.
     */
    function setMaxWalletBps(uint256 _newMaxWalletBps) external onlyOwner {
        require(_newMaxWalletBps <= 10000, "Cannot exceed 100%"); // Safety limit
        maxWalletBps = _newMaxWalletBps;
        emit MaxWalletBpsUpdated(_newMaxWalletBps);
    }

    function _update(address sender, address recipient, uint256 amount) internal override {
        uint256 fee = 0;
        uint256 marketingShare = 0;
        uint256 rewardsShare = 0;

        // Apply max transaction limit only if sender or recipient is a liquidity pool
        if (isLiquidityPool[sender] || isLiquidityPool[recipient]) {
            uint256 maxTransactionAmount = _convertBpsToAmount(maxTransactionBps);
            require(amount <= maxTransactionAmount, "Exceeds max transaction limit");
        }

        // Apply fees only if the sender/recipient is NOT exempt
        if (!exemptedFromFees[sender] && !exemptedFromFees[recipient]) {
            if (isLiquidityPool[sender]) {
                // Buy fee
                fee = (amount * buyFee) / 100;
            } else if (isLiquidityPool[recipient]) {
                // Sell fee
                fee = (amount * sellFee) / 100;
            } else {
                // Transfer fee
                fee = (amount * TRANSFER_FEE) / 100;
            }

            // Dynamically allocate rewards and marketing shares
            rewardsShare = (fee * rewardsPercentage) / 100;
            marketingShare = fee - rewardsShare;
            // Apply max wallet balance restriction only if the recipient is NOT a liquidity pool
            if (!isLiquidityPool[recipient]) {
                uint256 maxWalletBalance = _convertBpsToAmount(maxWalletBps);
                require(balanceOf(recipient) + (amount - fee) <= maxWalletBalance, "Exceeds max wallet balance");
            }
            // Process fees
            if (fee > 0) {
                _internalTransfer(sender, marketingWallet, marketingShare);
                if (rewardsShare > 0) {
                    _internalTransfer(sender, address(this), rewardsShare);
                }
            }
        }

        // Transfer remaining amount
        uint256 transferAmount = amount - fee;
        super._update(sender, recipient, transferAmount);

        // Update holders list
        if (balanceOf(sender) == 0) _removeHolder(sender);
        _addHolder(recipient);
    }

    function addLiquidityPool(address pool, bool status) external onlyOwner {
        if (pool == address(0)) revert InvalidAddress();
        isLiquidityPool[pool] = status;
        emit LiquidityPoolAdded(pool, status);
    }

    /**
     * @notice Calculates the total eligible balance by excluding ineligible and below-threshold holders.
     * @return totalEligibleBalance The total supply minus ineligible balances.
     */
    function getTotalEligibleBalance() public view returns (uint256 totalEligibleBalance) {
        uint256 totalIneligibleBalance = 0;

        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 holderBalance = balanceOf(holder);

            // Exclude addresses either excluded manually or holding below minHoldForRewards
            if (excludedFromRewards[holder] || holderBalance < minHoldForRewards) {
                totalIneligibleBalance += holderBalance;
            }
        }

        return totalSupply() - totalIneligibleBalance;
    }

    /**
     * @notice Distributes all ETH in the contract to eligible holders who meet minHoldForRewards.
     */
    function distributeETHRewards() external nonReentrant {
        uint256 totalETH = address(this).balance;
        if (totalETH == 0) revert NoRewardsAvailable();

        uint256 totalEligibleBalance = getTotalEligibleBalance();
        if (totalEligibleBalance == 0) revert NoRewardsAvailable();

        uint256 distributedAmount = 0;

        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 holderBalance = balanceOf(holder);

            // Ensure the holder is not excluded and meets the minimum balance requirement
            if (!excludedFromRewards[holder] && holderBalance >= minHoldForRewards) {
                uint256 holderShare = (holderBalance * 1e18) / totalEligibleBalance;
                uint256 reward = (totalETH * holderShare) / 1e18;

                if (reward > 0) {
                    (bool success, ) = payable(holder).call{value: reward}("");
                    if (success) {
                        distributedAmount += reward;
                    }
                }
            }
        }

        emit ReflectionDistributed(distributedAmount);
    }

    function updateFeesInstantly(uint256 newBuyFee, uint256 newSellFee) external onlyOwner {
        require(newBuyFee <= 10000 && newSellFee <= 10000, "Fees too high!"); // Ensuring fees are reasonable
        buyFee = newBuyFee / 100;
        sellFee = newSellFee / 100;
        emit FeesUpdated(newBuyFee, newSellFee);
    }

    function withdrawBOLTokens(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 contractBalance = balanceOf(address(this));
        require(amount > 0 && amount <= contractBalance, "Invalid amount");

        _internalTransfer(address(this), to, amount);
    }

    /**
     * @notice Withdraws any ERC-20 token mistakenly sent to the contract.
     * @param token The address of the ERC-20 token.
     * @param recipient The address to receive the withdrawn tokens.
     * @param amount The amount of tokens to withdraw.
     */
    function withdrawTokens(address token, address recipient, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient address");

        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));

        require(amount <= balance, "Insufficient contract balance");

        bool success = erc20.transfer(recipient, amount);
        require(success, "Token transfer failed");
    }

    function withdrawExcessETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH available");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "ETH withdrawal failed");
        emit ETHWithdrawn(owner(), balance);
    }

    /**
     * @dev Adds an address to the list of holders if it has a balance.
     * @param account The address to add.
     */

    function _addHolder(address account) internal {
        if (holderIndex[account] != 0 || balanceOf(account) == 0) return; // Avoid redundant operations

        uint256 length = holders.length;
        holders.push(account);
        holderIndex[account] = length + 1; // Store index as length + 1 (1-based indexing)
    }

    function updateTransferFee(uint256 newFee) external onlyOwner {
        require(newFee < 10000, "Fee too high!"); // Set a transfer fee
        TRANSFER_FEE = newFee / 100;
    }

    /**
     * @dev Removes an address from the list of holders if it has no balance.
     * @param account The address to remove.
     */

    function _removeHolder(address account) internal {
        if (holderIndex[account] == 0 || balanceOf(account) > 0) return; // Avoid unnecessary operations

        uint256 index = holderIndex[account] - 1; // Convert from 1-based to 0-based index
        uint256 lastIndex = holders.length - 1;

        if (index != lastIndex) {
            // Swap only if it's not the last element
            address lastHolder = holders[lastIndex];
            holders[index] = lastHolder;
            holderIndex[lastHolder] = index + 1;
        }

        holders.pop(); // Remove the last element
        delete holderIndex[account]; // Reset the mapping
    }

    /**
     * @notice Retrieves the address of a holder at a specific index.
     * @param index The index of the holder.
     * @return The address of the holder.
     */
    function holderAt(uint256 index) public view returns (address) {
        if (index >= holders.length) revert IndexOutOfBounds();
        return holders[index];
    }

    /**
     * @notice Returns the total number of holders.
     * @return The number of holders.
     */
    function holderCount() public view returns (uint256) {
        return holders.length;
    }

    /**
     * @notice Sets whether an address is excluded from reflection rewards.
     * @param account The address to exclude or include.
     * @param excluded Whether the address should be excluded.
     */
    function setExcludedFromRewards(address account, bool excluded) external onlyOwner {
        excludedFromRewards[account] = excluded;
        emit ExclusionUpdated(account, excluded);
    }

    /**
     * @notice Sets whether an address is exempted from fees.
     * @param account The address to exempt or include.
     * @param exempted Whether the address should be exempted.
     */
    function setExemptedFromFees(address account, bool exempted) external onlyOwner {
        exemptedFromFees[account] = exempted;
    }

    /**
     * @notice Allows the contract to receive ETH for reflection and liquidity purposes.
     */
    receive() external payable {}
}
