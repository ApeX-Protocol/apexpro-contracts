// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "../interfaces/IStarkEx.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 *
 * MarketMaker
 *
 */
contract MarketMaker is ReentrancyGuard {
  using SafeERC20 for IERC20;

  // Events
  event Deposit(address from, address token, uint256 amount, uint256 starkKey, uint256 positionId);
  event WithdrawETH(uint256 orderId, address to, uint256 value);
  event WithdrawERC20(uint256 orderId, address token, address to, uint256 value);

  // Public fields
  address immutable public USDC_ADDRESS;                  // USDC contract address
  address immutable public STARKEX_ADDRESS;               // stark exchange adress
  uint256 public ASSET_TYPE;                              // starkex USDC asset type 
  uint256 public VAULT_ID;                                // market maker l2 account id
  address[] public signers;                               // The addresses that can co-sign transactions on the wallet
  mapping(uint256 => order) orders;                       // history orders

  struct order{
    address to;     // The address the transaction was sent to
    uint256 amount;  // Amount of Wei sent to the address
    address token;  // The address of the ERC20 token contract, 0 means ETH
    bool executed;  // If the order was executed
  }

  /**
   * Set up a simple 2-3 multi-sig wallet by specifying the signers allowed to be used on this wallet.
   * 2 signers will be require to send a transaction from this wallet.
   * Note: The sender is NOT automatically added to the list of signers.
   * Signers CANNOT be changed once they are set
   *
   * @param allowedSigners      An array of signers on the wallet
   * @param usdc                The USDC contract address
   * @param starkex             The stark exchange address
   * @param assetType           The stark usdc asset type
   * @param vaultId             The stark account id
   */
  constructor(address[] memory allowedSigners, address usdc,address starkex, uint256 assetType, uint256 vaultId) {
    require(allowedSigners.length == 3, "invalid allSigners length");
    require(allowedSigners[0] != allowedSigners[1], "must be different signers");
    require(allowedSigners[0] != allowedSigners[2], "must be different signers");
    require(allowedSigners[1] != allowedSigners[2], "must be different signers");

    signers = allowedSigners;
    USDC_ADDRESS = usdc;
    STARKEX_ADDRESS = starkex;
    ASSET_TYPE = assetType;
    VAULT_ID = vaultId;
  }

  /**
   * Gets called when a transaction is received without calling a method
   */
  receive() external payable { }

  /**
    * @notice Make a deposit to the Starkware Layer2
    *
    * @param  token              The ERC20 token to convert from
    * @param  amount             The amount in Wei to deposit.
    * @param  starkKey           The starkKey of the L2 account to deposit into.
    * @param  positionId         The positionId of the L2 account to deposit into.
    */
  function deposit(
    IERC20 token,
    uint256 amount,
    uint256 starkKey,
    uint256 positionId
  ) public payable nonReentrant {
    require(positionId == VAULT_ID, "invalid positionId");

    // only support USDC deposit
    require(address(token) == USDC_ADDRESS, "invalid USDC token");
    token.safeTransferFrom(msg.sender, address(this), amount);
   
    // safeApprove requires unsetting the allowance first.
    token.safeApprove(STARKEX_ADDRESS, 0);
    token.safeApprove(STARKEX_ADDRESS, amount);

    IStarkEx starkEx = IStarkEx(STARKEX_ADDRESS);
    address ownerAddress = starkEx.getEthKey(starkKey);
    // make sure that the L2 user had bind the contract address
    require(ownerAddress == address(this), "invalid eth key");

    // deposit to starkex
    starkEx.depositERC20(starkKey, ASSET_TYPE, VAULT_ID, amount);

    emit Deposit(
      msg.sender,
      address(token),
      amount,
      starkKey,
      positionId
    );
  }

  /**
  * registerOwnerKey bind the contract address and starkKey, 
  * so user can only withdraw to this wallet address.
  *
  * @param  starkKey           The starkKey of the L2 account to deposit into.
  * @param  starkSignature     The signature signed by stark key privatekey.
  */

  function registerOwnerKey( 
    uint256 starkKey,
    bytes calldata starkSignature) public {
    require(starkKey != 0, "invalid stark key");
    require(starkSignature.length == 32 * 3, "invalid stark signature length");

    IStarkEx starkEx = IStarkEx(STARKEX_ADDRESS);
    starkEx.registerEthAddress(address(this), starkKey, starkSignature);
  }

 /**
  * getWithdrawalBalance query withdrawable balance from starkex
  *
  * @param  starkKey          The starkKey of the L2 account to deposit into.
  * @param  assetId           The assetId in L2.
  */
  function getWithdrawalBalance( 
    uint256 starkKey,
    uint256 assetId
  ) public view returns (uint256){
    require(starkKey != 0, "invalid stark key");
    require(assetId != 0, "invalid asset id");
    IStarkEx starkEx = IStarkEx(STARKEX_ADDRESS);
    return starkEx.getWithdrawalBalance(starkKey, assetId);
  }

  /**
  * withdrawClaim withdraw balance from starkex to this wallet
  *
  * @param  starkKey          The starkKey of the L2 account to deposit into.
  * @param  assetId           The assetId in L2.
  */
  function withdrawClaim(  
    uint256 starkKey,
    uint256 assetId
    ) public {
    IStarkEx starkEx = IStarkEx(STARKEX_ADDRESS);
    uint256 avaliableBalance = starkEx.getWithdrawalBalance(starkKey, assetId);
    require(avaliableBalance > 0, "insufficient avaliable balance");
    starkEx.withdraw(starkKey, assetId);
  }

  /**
   * Withdraw ETHER from this wallet using 2 signers.
   *
   * @param  to         the destination address to send an outgoing transaction
   * @param  amount     the amount in Wei to be sent
   * @param  expireTime the number of seconds since 1970 for which this transaction is valid
   * @param  orderId    the unique order id 
   * @param  allSigners all signer who sign the tx
   * @param  signatures the signatures of tx
   */
  function withdrawETH(
    address payable to,
    uint256 amount,
    uint256 expireTime,
    uint256 orderId,
    address[] memory allSigners,
    bytes[] memory signatures
  ) public nonReentrant {
    require(allSigners.length >= 2, "invalid signers length");
    require(allSigners.length == signatures.length, "invalid signatures length");
    require(allSigners[0] != allSigners[1], "can not be same signer"); // must be different signer
    require(expireTime >= block.timestamp, "expired transaction");

    bytes32 operationHash = keccak256(abi.encodePacked("ETHER", to, amount, expireTime, orderId, address(this)));
    operationHash = ECDSA.toEthSignedMessageHash(operationHash);

    for (uint8 index = 0; index < allSigners.length; index++) {
        address signer = ECDSA.recover(operationHash, signatures[index]);
        require(signer == allSigners[index], "invalid signer");
        require(isAllowedSigner(signer),"not allowed signer");
    }

    // Try to insert the order ID. Will revert if the order id was invalid
    tryInsertOrderId(orderId, to, amount, address(0));

    // Success, send the transaction
    require(address(this).balance >= amount, "Address: insufficient balance");
    (bool success, ) = to.call{value: amount}("");
    require(success, "Address: unable to send value, recipient may have reverted");

    emit WithdrawETH(orderId, to, amount);
  }
  
  /**
   * Withdraw ERC20 from this wallet using 2 signers.
   *
   * @param  to         the destination address to send an outgoing transaction
   * @param  amount     the amount in tokens to be sent
   * @param  token      the address of the erc20 token contract
   * @param  expireTime the number of seconds since 1970 for which this transaction is valid
   * @param  orderId    the unique order id 
   * @param  allSigners all signer who sign the tx
   * @param  signatures the signatures of tx
   */
  function withdrawErc20(
    address to,
    uint256 amount,
    address token,
    uint256 expireTime,
    uint256 orderId,
    address[] memory allSigners,
    bytes[] memory signatures
  ) public nonReentrant {
    require(allSigners.length >=2, "invalid allSigners length");
    require(allSigners.length == signatures.length, "invalid signatures length");
    require(allSigners[0] != allSigners[1], "can not be same signer"); // must be different signer
    require(expireTime >= block.timestamp, "expired transaction");

    bytes32 operationHash = keccak256(abi.encodePacked("ERC20", to, amount, token, expireTime, orderId, address(this)));
    operationHash = ECDSA.toEthSignedMessageHash(operationHash);

    for (uint8 index = 0; index < allSigners.length; index++) {
      address signer = ECDSA.recover(operationHash, signatures[index]);
      require(signer == allSigners[index], "invalid signer");
      require(isAllowedSigner(signer),"not allowed signer");
    }

    // Try to insert the order ID. Will revert if the order id was invalid
    tryInsertOrderId(orderId, to, amount, token);

    // Success, send ERC20 token
    IERC20 erc20 = IERC20(token);
    erc20.safeTransfer(to, amount);

    emit WithdrawERC20(orderId, token, to, amount);
  }

  /**
   * Determine if an address is a signer on this wallet
   *
   * @param signer address to check
   */
  function isAllowedSigner(address signer) public view returns (bool) {
    for (uint i = 0; i < signers.length; i++) {
      if (signers[i] == signer) {
        return true;
      }
    }
    return false;
  }
  

  /**
   * Verify that the order id has not been used before and inserts it. Throws if the order ID was not accepted.
   *
   * @param orderId   the unique order id 
   * @param to        the destination address to send an outgoing transaction
   * @param amount     the amount in Wei to be sent
   * @param token     the address of the ERC20 contract
   */
  function tryInsertOrderId(
      uint256 orderId, 
      address to,
      uint256 amount, 
      address token
    ) internal {
    if (orders[orderId].executed) {
        // This order ID has been excuted before. Disallow!
        revert("repeated order");
    }

    orders[orderId].executed = true;
    orders[orderId].to = to;
    orders[orderId].amount = amount;
    orders[orderId].token = token;
  }

  /**
   * calcSigHash is a helper function that to help you generate the sighash needed for withdrawal.
   *
   * @param to          the destination address
   * @param amount      the amount in Wei to be sent
   * @param token       the address of the ERC20 contract
   * @param expireTime  the number of seconds since 1970 for which this transaction is valid
   * @param orderId     the unique order id 
   */

  function calcSigHash(
    address to,
    uint256 amount,
    address token,
    uint256 expireTime,
    uint256 orderId) public view returns (bytes32) {
    bytes32 operationHash;
    if (token == address(0)) {
      operationHash = keccak256(abi.encodePacked("ETHER", to, amount, expireTime, orderId, address(this)));
    } else {
      operationHash = keccak256(abi.encodePacked("ERC20", to, amount, token, expireTime, orderId, address(this)));
    }
    return operationHash;
  }
}