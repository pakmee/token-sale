pragma solidity ^0.4.11;
import "zeppelin-solidity/contracts/token/StandardToken.sol";
import "zeppelin-solidity/contracts/SafeMath.sol";

contract CATToken is StandardToken {
	using SafeMath for uint256;

	// keccak256 hash of hidden cap
	string public constant HIDDEN_CAP = "0xd22f19d54193ff5e08e7ba88c8e52ec1b9fc8d4e0cf177e1be8a764fa5b375fa";

	// Events
	event CreatedCAT(address indexed _creator, uint256 _amountOfCAT);
	event CATRefundedForWei(address indexed _refunder, uint256 _amountOfWei);

	// Token data
	string public constant name = "BlockCAT Token";
	string public constant symbol = "CAT";
	uint256 public constant decimals = 18;  // Since our decimals equals the number of wei per ether, we needn't multiply sent values when converting between CAT and ETH.
	string public version = "1.0";

	// Addresses and contracts
	address public executor;
	address public devETHDestination;
	address public devCATDestination;
	address public reserveCATDestination;

	// Sale data
	bool public saleHasEnded;
	bool public minCapReached;
	bool public allowRefund;
	mapping (address => uint256) public ETHContributed;
	uint256 public totalETHRaised;
	uint256 public saleStartBlock;
	uint256 public saleEndBlock;
	uint256 public saleFirstEarlyBirdEndBlock;
	uint256 public saleSecondEarlyBirdEndBlock;
	uint256 public constant DEV_PORTION = 20;  // In percentage
	uint256 public constant RESERVE_PORTION = 1;  // In percentage
	uint256 public constant ADDITIONAL_PORTION = DEV_PORTION + RESERVE_PORTION;
	uint256 public constant SECURITY_ETHER_CAP = 1000000 ether;
	uint256 public constant CAT_PER_ETH_BASE_RATE = 300;  // 300 CAT = 1 ETH during normal part of token sale
	uint256 public constant CAT_PER_ETH_FIRST_EARLY_BIRD_RATE = 330;
	uint256 public constant CAT_PER_ETH_SECOND_EARLY_BIRD_RATE = 315;

	function CATToken(
		address _devETHDestination,
		address _devCATDestination,
		address _reserveCATDestination,
		uint256 _saleStartBlock,
		uint256 _saleEndBlock
	) {
		// Reject on invalid ETH destination address or CAT destination address
		if (_devETHDestination == address(0x0)) revert();
		if (_devCATDestination == address(0x0)) revert();
		if (_reserveCATDestination == address(0x0)) revert();
		// Reject if sale ends before the current block
		if (_saleEndBlock <= block.number) revert();
		// Reject if the sale end time is less than the sale start time
		if (_saleEndBlock <= _saleStartBlock) revert();

		executor = msg.sender;
		saleHasEnded = false;
		minCapReached = false;
		allowRefund = false;
		devETHDestination = _devETHDestination;
		devCATDestination = _devCATDestination;
		reserveCATDestination = _reserveCATDestination;
		totalETHRaised = 0;
		saleStartBlock = _saleStartBlock;
		saleEndBlock = _saleEndBlock;
		saleFirstEarlyBirdEndBlock = saleStartBlock + 6171;  // Equivalent to 24 hours later, assuming 14 second blocks
		saleSecondEarlyBirdEndBlock = saleFirstEarlyBirdEndBlock + 12342;  // Equivalent to 48 hours later after first early bird, assuming 14 second blocks

		totalSupply = 0;
	}

	function createTokens() payable external {
		// If sale is not active, do not create CAT
		if (saleHasEnded) revert();
		if (block.number < saleStartBlock) revert();
		if (block.number > saleEndBlock) revert();
		// Check if the balance is greater than the security cap
		uint256 newEtherBalance = totalETHRaised.add(msg.value);
		if (newEtherBalance > SECURITY_ETHER_CAP) revert();
		// Do not do anything if the amount of ether sent is 0
		if (0 == msg.value) revert();

		// Calculate the CAT to ETH rate for the current time period of the sale
		uint256 curTokenRate = CAT_PER_ETH_BASE_RATE;
		if (block.number < saleFirstEarlyBirdEndBlock) {
			curTokenRate = CAT_PER_ETH_FIRST_EARLY_BIRD_RATE;
		}
		else if (block.number < saleSecondEarlyBirdEndBlock) {
			curTokenRate = CAT_PER_ETH_SECOND_EARLY_BIRD_RATE;
		}

		// Calculate the amount of CAT being purchased
		uint256 amountOfCAT = msg.value.mul(curTokenRate);

		// Ensure that the transaction is safe
		uint256 totalSupplySafe = totalSupply.add(amountOfCAT);
		uint256 balanceSafe = balances[msg.sender].add(amountOfCAT);
		uint256 contributedSafe = ETHContributed[msg.sender].add(msg.value);

		// Update individual and total balances
		totalSupply = totalSupplySafe;
		balances[msg.sender] = balanceSafe;

		totalETHRaised = newEtherBalance;
		ETHContributed[msg.sender] = contributedSafe;

		CreatedCAT(msg.sender, amountOfCAT);
	}

	function endSale() {
		// Do not end an already ended sale
		if (saleHasEnded) revert();
		// Can't end a sale that hasn't hit its minimum cap
		if (!minCapReached) revert();
		// Only allow the owner to end the sale
		if (msg.sender != executor) revert();

		saleHasEnded = true;

		// Calculate and create developer and reserve portion of CAT
		uint256 additionalCAT = (totalSupply.mul(ADDITIONAL_PORTION)).div(100 - ADDITIONAL_PORTION);
		uint256 totalSupplySafe = totalSupply.add(additionalCAT);

		uint256 reserveShare = (additionalCAT.mul(RESERVE_PORTION)).div(ADDITIONAL_PORTION);
		uint256 devShare = additionalCAT.sub(reserveShare);

		totalSupply = totalSupplySafe;
		balances[devCATDestination] = devShare;
		balances[reserveCATDestination] = reserveShare;

		CreatedCAT(devCATDestination, devShare);
		CreatedCAT(reserveCATDestination, reserveShare);

		if (this.balance > 0) {
			if (!devETHDestination.call.value(this.balance)()) revert();
		}
	}

	// Allows BlockCAT to withdraw funds
	function withdrawFunds() {
		// Disallow withdraw if the minimum hasn't been reached
		if (!minCapReached) revert();
		if (0 == this.balance) revert();

		if (!devETHDestination.call.value(this.balance)()) revert();
	}

	// Signals that the sale has reached its minimum funding goal
	function triggerMinCap() {
		if (msg.sender != executor) revert();

		minCapReached = true;
	}

	// Opens refunding.
	function triggerRefund() {
		// No refunds if the sale was successful
		if (saleHasEnded) revert();
		// No refunds if minimum cap is hit
		if (minCapReached) revert();
		// No refunds if the sale is still progressing
		if (block.number < saleEndBlock) revert();
		if (msg.sender != executor) revert();

		allowRefund = true;
	}

	function refund() external {
		// No refunds until it is approved
		if (!allowRefund) revert();
		// Nothing to refund
		if (0 == ETHContributed[msg.sender]) revert();

		// Do the refund.
		uint256 etherAmount = ETHContributed[msg.sender];
		ETHContributed[msg.sender] = 0;

		CATRefundedForWei(msg.sender, etherAmount);
		if (!msg.sender.send(etherAmount)) revert();
	}

	function changeDeveloperETHDestinationAddress(address _newAddress) {
		if (msg.sender != executor) revert();
		devETHDestination = _newAddress;
	}

	function changeDeveloperCATDestinationAddress(address _newAddress) {
		if (msg.sender != executor) revert();
		devCATDestination = _newAddress;
	}

	function changeReserveCATDestinationAddress(address _newAddress) {
		if (msg.sender != executor) revert();
		reserveCATDestination = _newAddress;
	}

	function transfer(address _to, uint _value) {
		// Cannot transfer unless the minimum cap is hit
		if (!minCapReached) revert();

		super.transfer(_to, _value);
	}

	function transferFrom(address _from, address _to, uint _value) {
		// Cannot transfer unless the minimum cap is hit
		if (!minCapReached) revert();

		super.transferFrom(_from, _to, _value);
	}
}
