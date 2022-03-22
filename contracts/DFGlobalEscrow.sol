// SPDX-License-Identifier: UNLICENSED
/**
 * Code review assessment from the DAOFEB
 * TODO
    Based on your undeerstanding of the escrow use case, 
    `review` the code and `identify` possible weakness,
    missing functions and areas of improvements.
 **** description ****
  In broad, an escrow arrangement flow is as follows.
  1) Recipient/Sender (or a third-party) may create an escrow account(s) with an Escrow
  2) Sender may initiate fund transfer to the Escrow account
  3) both Sender and Recipient(2 out of 3 parties) can agree to the release of the funds to Recipient
      or a revert of funds to the Sender
  4) In the event that both the Sender and Recipient are unable to jointly agree to the release
       or revert of funds, an Escrow Agent may adjudicate the release or refund of funds
       based on terms of the escrow agreement
  5) Recipient/Sender's signature can be based no a single mandate/multi-signature approach where
       all relevant signatories must authorise the particular blockchain action.
 */
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface CEth {
    function mint() external payable;

    function exchangeRateCurrent() external returns (uint256);

    function supplyRatePerBlock() external returns (uint256);

    function redeem(uint256) external returns (uint256);

    function redeemUnderlying(uint256) external returns (uint256);
}

interface CERC20 {
    function mint(uint256) external returns (uint256);

    function exchangeRateCurrent() external returns (uint256);

    function supplyRatePerBlock() external returns (uint256);

    function redeem(uint256) external returns (uint256);

    function redeemUnderlying(uint256) external returns (uint256);
}

contract DFGlobalEscrow is Ownable {
    enum Sign {
        NULL,
        REVERT,
        RELEASE
    }

    enum TokenType {
        ETH,
        ERC20
    }

    struct EscrowRecord {
        string referenceId;
        address payable delegator;
        address payable owner;
        address payable recipient;
        address payable agent;
        TokenType tokenType;
        /**
         * @dev ERC20 token address
         * 0 when the TokenType is ETH
         */
        address tokenAddress;
        /**
         * @dev C TOKEN address for the COMPOUND reward
         * C_ETHER_TOKEN_ADDRESS when tokenType is ETH,
         * C_ERC20_TOKEN_ADDRESS when tokenType is ERC20
         */
        address payable cTokenAddress;
        uint256 fund;
        mapping(address => bool) signer;
        mapping(address => Sign) signed;
        uint256 releaseCount;
        uint256 revertCount;
        uint256 lastTxBlock;
        bool funded;
        bool disputed;
        bool finalized;
        bool shouldInvest;
    }

    mapping(string => EscrowRecord) private _escrow;

    constructor() {}

    function isSigner(string memory _referenceId, address _signer)
        public
        view
        returns (bool)
    {
        return _escrow[_referenceId].signer[_signer];
    }

    function getSignedAction(string memory _referenceId, address _signer)
        public
        view
        returns (Sign)
    {
        return _escrow[_referenceId].signed[_signer];
    }

    // @audit index the fields properly
    event EscrowInitiated(
        string referenceId,
        address payer,
        uint256 amount,
        address payee,
        address trustedParty,
        uint256 lastBlock
    );
    event Signature(
        string referenceId,
        address signer,
        Sign action,
        uint256 lastBlock
    );
    event Finalized(string referenceId, address winner, uint256 lastBlock);
    event Disputed(string referenceId, address disputer, uint256 lastBlock);
    event Withdrawn(
        string referenceId,
        address payee,
        uint256 amount,
        uint256 lastBlock
    );
    event Funded(
        string indexed referenceId,
        address indexed owner,
        uint256 amount,
        uint256 lastBlock
    );

    // for string logs with numbers
    event DaoFebLog(string logStr, uint256 logValue);

    modifier multisigcheck(string memory _referenceId, address _party) {
        EscrowRecord storage e = _escrow[_referenceId];

        require(!e.finalized, "Escrow should not be finalized");
        require(e.signer[_party], "Party should be eligible to sign");
        require(
            e.signed[_party] == Sign.NULL,
            "Party should not have signed already"
        );
        _;
        if (e.releaseCount == 2) transferOwnership(e);
        else if (e.revertCount == 2) finalize(e);
        else if (e.releaseCount == 1 && e.revertCount == 1) dispute(e, _party);
    }

    modifier onlyEscrowOwner(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender,
            "Sender must be Escrow's owner"
        );
        _;
    }

    modifier onlyEscrowOwnerOrDelegator(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
                _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's owner or delegator"
        );
        _;
    }

    modifier onlyEscrowPartyOrDelegator(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
                _escrow[_referenceId].recipient == msg.sender ||
                _escrow[_referenceId].agent == msg.sender ||
                _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's Owner or Recipient or Agent or Delegator"
        );
        _;
    }

    modifier onlyEscrowOwnerOrRecipientOrDelegator(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
                _escrow[_referenceId].recipient == msg.sender ||
                _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's Owner or Recipient or Delegator"
        );
        _;
    }

    modifier isFunded(string memory _referenceId) {
        require(
            _escrow[_referenceId].funded == true,
            "Escrow should be funded"
        );
        _;
    }

    // @audit payable is not necessary.
    // In the creation of escrow, we don't need to receiver either, so the `payable` is not necessary

    // @audit should remove onlyOwner modifier
    // if we have onlyOwner in the modifier list, it only allows the contract owner to create escrow accounts
    // if so, only the contract owner can be the sender of an escrow
    // @dev the caller of this method can be sender, recipient or agent.
    // otherwise, it will be the delegator, who initiates funds instead of the sender.
    function createEscrow(
        string memory _referenceId,
        address payable _owner,
        address payable _recipient,
        address payable _agent,
        TokenType tokenType,
        address erc20TokenAddress,
        address payable cTokenAddress,
        uint256 tokenAmount,
        bool _shouldInvest /*payable*/ // onlyOwner
    ) public {
        require(msg.sender != address(0), "Sender should not be null");
        // @audit incorrect message
        // require(_owner != address(0), "Recipient should not be null");
        require(_owner != address(0), "Owner should not be null");
        require(_recipient != address(0), "Recipient should not be null");
        require(_agent != address(0), "Trusted agent should not be null");
        require(_escrow[_referenceId].lastTxBlock == 0, "Duplicated Escrow");

        EscrowRecord storage e = _escrow[_referenceId];

        // @audit a more detailed check about the parties of the escrow.
        require(_owner != _recipient, "Recipient cannot be the same as sender");
        require(_owner != _agent, "The trusted agent cannot be the sender");
        require(
            _recipient != _agent,
            "The trusted agent cannot be the recipient"
        );

        e.referenceId = _referenceId;
        e.owner = _owner;
        if (e.owner != msg.sender) {
            // @audit if the caller of this method is not the sender, we regard this caller as the delegator of the sender.
            // in this case, the recipient and the agent cannot be the delegator
            // in some cases, the agent might be possible to be the delegator, but not preferable
            require(
                msg.sender != _recipient && msg.sender != _agent,
                "Invalid delegator"
            );
            e.delegator = payable(msg.sender);
        }
        e.recipient = _recipient;
        e.agent = _agent;

        e.tokenType = tokenType;
        e.funded = false;

        e.fund = tokenAmount;
        if (e.tokenType == TokenType.ERC20) {
            e.tokenAddress = erc20TokenAddress;
        }
        e.cTokenAddress = cTokenAddress;

        e.disputed = false;
        e.finalized = false;
        e.lastTxBlock = block.number;

        e.releaseCount = 0;
        e.revertCount = 0;

        e.signer[_owner] = true;
        e.signer[_recipient] = true;
        e.signer[_agent] = true;

        e.shouldInvest = _shouldInvest;

        emit EscrowInitiated(
            _referenceId,
            _owner,
            e.fund,
            _recipient,
            _agent,
            block.number
        );
    }

    function fund(string memory _referenceId, uint256 fundAmount)
        public
        payable
        onlyEscrowOwnerOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        require(e.lastTxBlock > 0, "Sender should not be null");

        uint256 escrowFund = e.fund;
        if (e.tokenType == TokenType.ETH) {
            // @audit the party wants to fund only escrowFund, but msg.value > escrowFund, where does the remaining amount go?
            // should change this line to `msg.value == escrowFund`

            // require(
            //     msg.value >= escrowFund,
            //     "Must fund for exact ETH-amount in Escrow"
            // );

            require(
                msg.value == escrowFund,
                "Must fund for exact ETH-amount in Escrow"
            );
        } else {
            require(
                fundAmount == escrowFund,
                "Must fund for exact ERC-20 amount in Escrow"
            );

            IERC20 erc20Instance = IERC20(e.tokenAddress);
            erc20Instance.transferFrom(msg.sender, address(this), fundAmount);
        }

        e.funded = true;
        emit Funded(_referenceId, e.owner, escrowFund, block.number);

        if (e.shouldInvest == false) return;

        // if the user wants to supply the escrow to the COMPOUND, do that.
        if (e.tokenType == TokenType.ETH) {
            supplyEthToCompound(e.cTokenAddress, e.fund);
        } else {
            supplyErc20ToCompound(e.tokenAddress, e.cTokenAddress, e.fund);
        }
    }

    // @audit should check with the msg.sender
    // msg.sender = owner of the escrow, but calls this function with the _party parameter set as recipient
    // @fix should add onlyOwner modifier
    //      or remove _party and call multisigcheck(_referenceId, msg.sender) or so
    // @audit no need to check onlyEscrowPartyOrDelegator
    function release(string memory _referenceId, address _party)
        public
        multisigcheck(_referenceId, _party)
    // onlyEscrowPartyOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        // @audit line is uselss
        // we checked if the _party is a signable party using the `multisigcheck` modifier
        // incorrect warning message
        // require(
        //     _party == e.owner || _party == e.recipient || _party == e.agent,
        //     "Only owner or recipient or agent can reverse an escrow"
        // );

        emit Signature(_referenceId, e.owner, Sign.RELEASE, e.lastTxBlock);

        // @audit this line is wrong
        // e.signed[e.owner] = Sign.RELEASE;
        // should be
        e.signed[_party] = Sign.RELEASE;
        e.releaseCount++;
    }

    function reverse(string memory _referenceId, address _party)
        public
        // @audit remove onlyEscrowPartyOrDelegator, delegator cannot call this function
        onlyEscrowPartyOrDelegator(_referenceId)
        multisigcheck(_referenceId, _party)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        // @audit line is uselss
        // we checked if the _party is a signable party.

        // require(
        //     _party == e.owner || _party == e.recipient || _party == e.agent,
        //     "Only owner or recipient or aget can reverse an escrow"
        // );

        emit Signature(_referenceId, e.owner, Sign.REVERT, e.lastTxBlock);

        // @audit this line is wrong
        // e.signed[e.owner] = Sign.REVERT;
        // should be
        e.signed[_party] = Sign.REVERT;
        e.revertCount++;
    }

    function dispute(string memory _referenceId, address _party)
        public
        onlyEscrowOwnerOrRecipientOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        require(!e.finalized, "Cannot dispute on a finalized Escrow");
        require(
            _party == e.owner || _party == e.recipient,
            "Only owner or recipient can dispute on escrow"
        );

        dispute(e, _party);
    }

    function transferOwnership(EscrowRecord storage e) internal {
        e.owner = e.recipient;
        finalize(e);
        e.lastTxBlock = block.number;
    }

    function dispute(EscrowRecord storage e, address _party) internal {
        emit Disputed(e.referenceId, _party, e.lastTxBlock);

        e.disputed = true;
        e.lastTxBlock = block.number;
    }

    function finalize(EscrowRecord storage e) internal {
        require(!e.finalized, "Escrow should not be finalized again");

        emit Finalized(e.referenceId, e.owner, e.lastTxBlock);

        e.finalized = true;
    }

    function withdraw(string memory _referenceId, uint256 _amount)
        public
        onlyEscrowOwner(_referenceId)
        isFunded(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];

        require(e.finalized, "Escrow should be finalized before withdrawal");
        require(_amount <= e.fund, "Cannot withdraw more than the depoisit");

        address escrowOwner = e.owner;

        emit Withdrawn(_referenceId, escrowOwner, _amount, e.lastTxBlock);

        e.fund = e.fund - _amount;
        e.lastTxBlock = block.number;

        if (e.shouldInvest == true) {
            // earn the rewards from the COMPOUND POOL
            if (e.tokenType == TokenType.ETH) {
                redeemCEth(_amount, false, e.cTokenAddress);
            } else {
                redeemCErc20Tokens(_amount, false, e.cTokenAddress);
            }
        } else {
            if (e.tokenType == TokenType.ETH) require((e.owner).send(_amount));
            else {
                IERC20 erc20Instance = IERC20(e.tokenAddress);
                // @audit ERC20 transfer always returns true. require is not needed
                // require(erc20Instance.transfer(escrowOwner, _amount));
                erc20Instance.transfer(escrowOwner, _amount);
            }
        }
    }

    function supplyEthToCompound(
        address payable _cEtherContract,
        uint256 amount
    ) public payable returns (bool) {
        // Create a reference to the corresponding cToken contract
        CEth cToken = CEth(_cEtherContract);

        // Amount of current exchange rate from cToken to underlying
        uint256 exchangeRateMantissa = cToken.exchangeRateCurrent();
        emit DaoFebLog(
            "Exchange Rate (scaled up by 1e18): ",
            exchangeRateMantissa
        );

        // Amount added to you supply balance this block
        uint256 supplyRateMantissa = cToken.supplyRatePerBlock();
        emit DaoFebLog("Supply Rate: (scaled up by 1e18)", supplyRateMantissa);

        cToken.mint{value: amount, gas: 250000}();
        return true;
    }

    function supplyErc20ToCompound(
        address _erc20Contract,
        address _cErc20Contract,
        uint256 _numTokensToSupply
    ) public returns (uint256) {
        // Create a reference to the underlying asset contract, like DAI.
        IERC20 underlying = IERC20(_erc20Contract);

        // Create a reference to the corresponding cToken contract, like cDAI
        CERC20 cToken = CERC20(_cErc20Contract);

        // Amount of current exchange rate from cToken to underlying
        uint256 exchangeRateMantissa = cToken.exchangeRateCurrent();
        emit DaoFebLog("Exchange Rate (scaled up): ", exchangeRateMantissa);

        // Amount added to you supply balance this block
        uint256 supplyRateMantissa = cToken.supplyRatePerBlock();
        emit DaoFebLog("Supply Rate: (scaled up)", supplyRateMantissa);

        // Approve transfer on the ERC20 contract
        underlying.approve(_cErc20Contract, _numTokensToSupply);

        // Mint cTokens
        uint256 mintResult = cToken.mint(_numTokensToSupply);
        return mintResult;
    }

    function redeemCErc20Tokens(
        uint256 amount,
        bool redeemType,
        address _cErc20Contract
    ) public returns (bool) {
        // Create a reference to the corresponding cToken contract, like cDAI
        CERC20 cToken = CERC20(_cErc20Contract);

        // `amount` is scaled up, see decimal table here:
        // https://compound.finance/docs#protocol-math

        uint256 redeemResult;

        if (redeemType == true) {
            // Retrieve your asset based on a cToken amount
            redeemResult = cToken.redeem(amount);
        } else {
            // Retrieve your asset based on an amount of the asset
            redeemResult = cToken.redeemUnderlying(amount);
        }

        // Error codes are listed here:
        // https://compound.finance/docs/ctokens#error-codes
        emit DaoFebLog("If this is not 0, there was an error", redeemResult);

        return true;
    }

    function redeemCEth(
        uint256 amount,
        bool redeemType,
        address _cEtherContract
    ) public returns (bool) {
        // Create a reference to the corresponding cToken contract
        CEth cToken = CEth(_cEtherContract);

        // `amount` is scaled up by 1e18 to avoid decimals

        uint256 redeemResult;

        if (redeemType == true) {
            // Retrieve your asset based on a cToken amount
            redeemResult = cToken.redeem(amount);
        } else {
            // Retrieve your asset based on an amount of the asset
            redeemResult = cToken.redeemUnderlying(amount);
        }

        // Error codes are listed here:
        // https://compound.finance/docs/ctokens#error-codes
        emit DaoFebLog("If this is not 0, there was an error", redeemResult);

        return true;
    }

    receive() external payable {}
}
