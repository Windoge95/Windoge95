// SPDX-License-Identifier: MIT

/*

                
██     ██ ██ ███    ██ ██████   ██████   ██████  ███████  █████  ███████ 
██     ██ ██ ████   ██ ██   ██ ██    ██ ██       ██      ██   ██ ██      
██  █  ██ ██ ██ ██  ██ ██   ██ ██    ██ ██   ███ █████    ██████ ███████ 
██ ███ ██ ██ ██  ██ ██ ██   ██ ██    ██ ██    ██ ██           ██      ██ 
 ███ ███  ██ ██   ████ ██████   ██████   ██████  ███████  █████  ███████ 
                                                                         

*/

pragma solidity ^0.8.6;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";
import "./IDex.sol";

/// @title WINDOGE95
/// @dev Auto-distribution of rewards in DOGE

library Address{
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }
}


contract WNDG95 is ERC20, Ownable {
    using SafeMath for uint256;
    using Address for address payable;

    IRouter public router;
    address public  pair;

    bool private swapping;
    bool public swapEnabled = true;

    WNDG95DividendTracker public dividendTracker;

    address public constant deadWallet = 0x000000000000000000000000000000000000dEaD;
    address public constant DOGE = address(0xbA2aE424d960c26247Dd6c32edC70B295c744C43); //DOGE
    address public windogeDefender;
    
    uint256 public swapTokensAtAmount = 200_000 * 10**9;
    uint256 public maxWalletBalance = 10_000_000 * 10**9;
    
            ///////////////
           //   Fees    //
          ///////////////
          
    uint256 public DOGERewardsFee = 4;
    uint256 public liquidityFee = 2;
    uint256 public windogeDefenderFee = 4;
    uint256 public totalFees = DOGERewardsFee.add(liquidityFee).add(windogeDefenderFee);

    uint256 public extraSellFee = 3;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;
    
         ////////////////
        //  Anti Bot  //
       ////////////////
       
    mapping (address => bool) private _isBot;
       
    mapping (address => bool) private _isExcludedFromFees;
    mapping (address => bool) public automatedMarketMakerPairs;
    mapping (address => bool) private authorized;
    
        ///////////////
       //   Events  //
      ///////////////
      
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event SendDividends(uint256 tokensSwapped,uint256 amount);
    event ProcessedDividendTracker(uint256 iterations,uint256 claims,uint256 lastProcessedIndex,bool indexed automatic,uint256 gas,address indexed processor);
    
    modifier onlyAuth() {
        require(msg.sender == owner() || authorized[msg.sender], "User not authorized");
        _;
    }

    constructor(address _windogeDefenderAddress) ERC20("WINDOGE95", "WNDG95") {

    	dividendTracker = new WNDG95DividendTracker();
    	windogeDefender = _windogeDefenderAddress;

    	IRouter _router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
         // Create a uniswap pair for this new token
        address _pair = IFactory(_router.factory()).createPair(address(this), _router.WETH());

        router = _router;
        pair = _pair;

        _setAutomatedMarketMakerPair(_pair, true);


        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker), true);
        dividendTracker.excludeFromDividends(address(this), true);
        dividendTracker.excludeFromDividends(owner(), true);
        dividendTracker.excludeFromDividends(deadWallet, true);
        dividendTracker.excludeFromDividends(address(_router), true);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(windogeDefender, true);
        

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 1e9 * (10**9));
    }

    receive() external payable {}

    function processDividendTracker(uint256 gas) external {
		(uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }
    
    /// @notice Manual claim the dividends after claimWait is passed
    ///    This can be useful during low volume days.
    function claim() external {
		dividendTracker.processAccount(msg.sender, false);
    }
    
    /// @notice Withdraw tokens sent by mistake.
    /// @param tokenAddress The address of the token to withdraw
    function rescueBEP20Tokens(address tokenAddress) external onlyAuth{
        IERC20(tokenAddress).transfer(msg.sender, IERC20(tokenAddress).balanceOf(address(this)));
    }
    
    /// @notice Send remaining BNB to windogeDefender
    /// @dev It will send all BNB to windogeDefender
    function forceSend() external {
        uint256 BNBbalance = address(this).balance;
        payable(windogeDefender).sendValue(BNBbalance);
    }
    
    
     /////////////////////////////////
    // Exclude / Include functions //
   /////////////////////////////////

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "WNDG95: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }
        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    /// @dev "true" to exlcude, "false" to include
    function excludeFromDividends(address account, bool value) external onlyOwner{
	    dividendTracker.excludeFromDividends(account, value);
	}


     ///////////////////////
    //  Setter Functions //
   ///////////////////////


    /// @dev Update windogeDefender address. It must be different
    ///   from the current one
    function setWindogeDefender(address newWindogeDefender) external onlyOwner{
        require(windogeDefender != newWindogeDefender, "windogeDefender already set");
        windogeDefender = newWindogeDefender;
    }

    function setMaxWallet(uint256 amount) external onlyAuth{
        maxWalletBalance = amount * 10**9;
    }

    /// @notice Update the threshold to swap tokens for liquidity,
    ///   marketing and dividends.
    function setSwapTokensAtAmount(uint256 amount) external onlyAuth{
        swapTokensAtAmount = amount * 10**9;
    }

    /// @notice Update DOGERewardsFee and totalFees
    /// @dev  Total fees must be less or equal to 40%.
    function setDOGERewardsFee(uint256 value) external onlyAuth{
        require(value.add(liquidityFee).add(windogeDefenderFee).add(extraSellFee) <= 40, "Total fees must be <= 40%");
        DOGERewardsFee = value;
        totalFees = DOGERewardsFee.add(liquidityFee).add(windogeDefenderFee);
    }

    /// @notice Update liquidityFee and totalFees
    /// @dev  Total fees must be less or equal to 40%.
    function setLiquiditFee(uint256 value) external onlyAuth{
        require(value.add(DOGERewardsFee).add(windogeDefenderFee).add(extraSellFee) <= 40, "Total fees must be <= 40%");
        liquidityFee = value;
        totalFees = DOGERewardsFee.add(liquidityFee).add(windogeDefenderFee);
    }

    /// @notice Update windogeDefenderFee and totalFees
    /// @dev  Total fees must be <= 40%.
    function setWindogeDefenderFee(uint256 value) external onlyAuth{
        require(value.add(liquidityFee).add(DOGERewardsFee).add(extraSellFee) <= 40, "Total fees must be <= 40%");
        windogeDefenderFee = value;
        totalFees = DOGERewardsFee.add(liquidityFee).add(windogeDefenderFee);
    }
    
    /// @notice Update extraSellFee
    /// @dev  Total fees must be <= 40%.
    function setExtraSellfee(uint256 value) external onlyAuth{
        require(totalFees.add(value) <= 40, "Total fees must bee <= 40%");
        extraSellFee = value;
    }

    /// @notice Enable or disable internal swaps
    /// @dev Set "true" to enable internal swaps for liquidity, marketing and dividends
    function setSwapEnabled(bool _enabled) external onlyAuth{
        swapEnabled = _enabled;
    }


    /// @param bot The bot address
    /// @param value "true" to blacklist, "false" to unblacklist
    function setBot(address bot, bool value) external onlyAuth{
        require(_isBot[bot] != value);
        _isBot[bot] = value;
    }

    /// @dev Set new pairs created due to listing in new DEX
    function setAutomatedMarketMakerPair(address newPair, bool value) external onlyOwner {
        _setAutomatedMarketMakerPair(newPair, value);
    }
    
    function setAuthorized(address account, bool value) external onlyOwner{
        authorized[account] = value;
        _isExcludedFromFees[account] = value;
    }

    function _setAutomatedMarketMakerPair(address newPair, bool value) private {
        require(automatedMarketMakerPairs[newPair] != value, "WNDG95: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[newPair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(newPair, true);
        }

        emit SetAutomatedMarketMakerPair(newPair, value);
    }

    /// @notice Update the gasForProcessing needed to auto-distribute rewards
    /// @param newValue The new amount of gas needed
    /// @dev The amount should not be greater than 500k to avoid expensive transactions
    function setGasForProcessing(uint256 newValue) external onlyAuth {
        require(newValue >= 200000 && newValue <= 500000, "WNDG95: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "WNDG95: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    /// @dev Update the dividendTracker claimWait
    function setClaimWait(uint256 claimWait) external onlyAuth {
        dividendTracker.updateClaimWait(claimWait);
    }

     //////////////////////
    // Getter Functions //
   //////////////////////

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }


    function isBot(address _bot) external view returns(bool){
        return _isBot[_bot];
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
    	return dividendTracker.withdrawableDividendOf(account);
  	}

  	function dividendTokenBalanceOf(address account) public view returns (uint256) {
  		return dividendTracker.balanceOf(account);
  	}

    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

	function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return dividendTracker.getAccountAtIndex(index);
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

     ////////////////////////
    // Transfer Functions //
   ////////////////////////

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(!_isBot[from] && !_isBot[to], "C:\\<windows95\\system32> kill bot");
        
        if(!_isExcludedFromFees[from] && !automatedMarketMakerPairs[to] && !_isExcludedFromFees[to]){
            require(balanceOf(to).add(amount) <= maxWalletBalance, "Balance is exceeding maxWalletBalance");
        }

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

		uint256 contractTokenBalance = balanceOf(address(this));
        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if( canSwap && !swapping && swapEnabled && !automatedMarketMakerPairs[from]) {
            swapping = true;

            contractTokenBalance = swapTokensAtAmount;

            if(liquidityFee > 0 || windogeDefenderFee > 0){
                uint256 swapTokens = contractTokenBalance.mul(liquidityFee.add(windogeDefenderFee)).div(totalFees);
                swapAndLiquify(swapTokens);
            }
            if(DOGERewardsFee > 0){
                uint256 sellTokens = contractTokenBalance.mul(DOGERewardsFee).div(totalFees);
                swapAndSendDividends(sellTokens);
            }

            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
        	uint256 fees = amount.mul(totalFees).div(100);
          // apply an extraSellFee during a sell
          // it is divided equally into the liquidity, marketing and rewards fee
          if(automatedMarketMakerPairs[to]){
              fees += amount.mul(extraSellFee).div(100);
          }
          amount = amount.sub(fees);
          super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(from, balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(to, balanceOf(to)) {} catch {}

        if(!swapping) {
	    	uint256 gas = gasForProcessing;

	    	try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
	    		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
	    	}
	    	catch {}
        }
    }

    function swapAndLiquify(uint256 tokens) private {
        // Split the contract balance into halves
        uint256 denominator= (liquidityFee + windogeDefenderFee) * 2;
        uint256 tokensToAddLiquidityWith = tokens * liquidityFee / denominator;
        uint256 toSwap = tokens - tokensToAddLiquidityWith;

        uint256 initialBalance = address(this).balance;

        swapTokensForBNB(toSwap);

        uint256 deltaBalance = address(this).balance - initialBalance;
        uint256 unitBalance= deltaBalance / (denominator - liquidityFee);
        uint256 bnbToAddLiquidityWith = unitBalance * liquidityFee;

        if(bnbToAddLiquidityWith > 0){
            // Add liquidity to pancake
            addLiquidity(tokensToAddLiquidityWith, bnbToAddLiquidityWith);
        }

        // Send BNB to windogeDefender
        uint256 windogeDefenderAmt = unitBalance * 2 * windogeDefenderFee;
        if(windogeDefenderAmt > 0){
            payable(windogeDefender).sendValue(windogeDefenderAmt);
        }
    }

    function swapTokensForBNB(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );

    }

    function swapTokensForDOGE(uint256 tokenAmount) private {

        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = router.WETH();
        path[2] = DOGE;

        _approve(address(this), address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(router), tokenAmount);

        // add the liquidity
        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            deadWallet,  //Lp generated by auto-lp will be locked forever
            block.timestamp
        );

    }

    function swapAndSendDividends(uint256 tokens) private{
        swapTokensForDOGE(tokens);
        uint256 dividends = IERC20(DOGE).balanceOf(address(this));
        bool success = IERC20(DOGE).transfer(address(dividendTracker), dividends);

        if (success) {
            dividendTracker.distributeDOGEDividends(dividends);
            emit SendDividends(tokens, dividends);
        }
    }
}

contract WNDG95DividendTracker is Ownable, DividendPayingToken {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;

    mapping (address => bool) public excludedFromDividends;

    mapping (address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public minimumTokenBalanceForDividends;

    event ExcludeFromDividends(address indexed account, bool value);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Claim(address indexed account, uint256 amount, bool indexed automatic);

    constructor()  DividendPayingToken("WNDG95_Dividen_Tracker", "WNDG95_Dividend_Tracker") {
    	claimWait = 3600;
    	minimumTokenBalanceForDividends = 10000 * (10**18); //must hold 10000 tokens
    }

    function _transfer(address, address, uint256) internal pure override {
        require(false, "WNDG95_Dividend_Tracker: No transfers allowed");
    }

    function withdrawDividend() public pure override {
        require(false, "WNDG95_Dividend_Tracker: withdrawDividend disabled. Use the 'claim' function on the main WNDG95 contract.");
    }

    function excludeFromDividends(address account, bool value) external onlyOwner {
    	require(excludedFromDividends[account] != value);
    	excludedFromDividends[account] = value;
      if(value == true){
        _setBalance(account, 0);
        tokenHoldersMap.remove(account);
      }
      else{
        _setBalance(account, balanceOf(account));
        tokenHoldersMap.set(account, balanceOf(account));
      }
      emit ExcludeFromDividends(account, value);

    }

    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(newClaimWait >= 3600 && newClaimWait <= 86400, "WNDG95_Dividend_Tracker: claimWait must be updated to between 1 and 24 hours");
        require(newClaimWait != claimWait, "WNDG95_Dividend_Tracker: Cannot update claimWait to same value");
        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }



    function getAccount(address _account)
        public view returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed,
            uint256 withdrawableDividends,
            uint256 totalDividends,
            uint256 lastClaimTime,
            uint256 nextClaimTime,
            uint256 secondsUntilAutoClaimAvailable) {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;

        if(index >= 0) {
            if(uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(int256(lastProcessedIndex));
            }
            else {
                uint256 processesUntilEndOfArray = tokenHoldersMap.keys.length > lastProcessedIndex ?
                                                        tokenHoldersMap.keys.length.sub(lastProcessedIndex) :
                                                        0;


                iterationsUntilProcessed = index.add(int256(processesUntilEndOfArray));
            }
        }


        withdrawableDividends = withdrawableDividendOf(account);
        totalDividends = accumulativeDividendOf(account);

        lastClaimTime = lastClaimTimes[account];

        nextClaimTime = lastClaimTime > 0 ?
                                    lastClaimTime.add(claimWait) :
                                    0;

        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp ?
                                                    nextClaimTime.sub(block.timestamp) :
                                                    0;
    }

    function getAccountAtIndex(uint256 index)
        public view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	if(index >= tokenHoldersMap.size()) {
            return (0x0000000000000000000000000000000000000000, -1, -1, 0, 0, 0, 0, 0);
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
    	if(lastClaimTime > block.timestamp)  {
    		return false;
    	}

    	return block.timestamp.sub(lastClaimTime) >= claimWait;
    }
    

    function setBalance(address account, uint256 newBalance) public onlyOwner {
    	if(excludedFromDividends[account]) {
    		return;
    	}
    	
    	if(newBalance >= minimumTokenBalanceForDividends) {
            _setBalance(account, newBalance);
    		tokenHoldersMap.set(account, newBalance);
    	}
    	
    	else {
            _setBalance(account, 0);
    		tokenHoldersMap.remove(account);
    	}

    	processAccount(account, true);
    }

    function process(uint256 gas) public returns (uint256, uint256, uint256) {
    	uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

    	if(numberOfTokenHolders == 0) {
    		return (0, 0, lastProcessedIndex);
    	}

    	uint256 _lastProcessedIndex = lastProcessedIndex;

    	uint256 gasUsed = 0;

    	uint256 gasLeft = gasleft();

    	uint256 iterations = 0;
    	uint256 claims = 0;

    	while(gasUsed < gas && iterations < numberOfTokenHolders) {
    		_lastProcessedIndex++;

    		if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
    			_lastProcessedIndex = 0;
    		}

    		address account = tokenHoldersMap.keys[_lastProcessedIndex];

    		if(canAutoClaim(lastClaimTimes[account])) {
    			if(processAccount(account, true)) {
    				claims++;
    			}
    		}

    		iterations++;

    		uint256 newGasLeft = gasleft();

    		if(gasLeft > newGasLeft) {
    			gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
    		}

    		gasLeft = newGasLeft;
    	}

    	lastProcessedIndex = _lastProcessedIndex;

    	return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address account, bool automatic) public onlyOwner returns (bool) {
        uint256 amount = _withdrawDividendOfUser(account);

    	if(amount > 0) {
    		lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
    		return true;
    	}

    	return false;
    }
}
