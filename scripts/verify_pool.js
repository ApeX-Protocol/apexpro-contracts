require("@nomiclabs/hardhat-etherscan");

const assetType = "0xa21edc9d9997b1b1956f542fe95922518a9e28ace11b7b2972a1974bf5971f";
// goerli env
const usdcAddress = "0xd44BB808bfE43095dBb94c83077766382D63952a";
const starkEx = "0x7478037C3a1F44f0Add4Ae06158fefD10d44Bb63";
const factAddress = "0x5070F5d37419AEAd10Df2252421e457336561269";
const oneInchAddress = "0x1111111254fb6c44bAC0beD2854e76F90643097d";

let pool = '0xC73ac64cE48750C5d273ab1886Aff3AF34cbA33f';
let signer;

var signers = [
  "0x9F41154D472dD406B907A2F6827d6Be5D3215bcB",
  "0x086E48b2752194E6cd85b7FEA18B1513162196b8",
  "0x94f397b322F3A914e15c6C058356F4839bCC5b1B",
];

/// below variables only for testnet
const main = async () => {
  const accounts = await hre.ethers.getSigners();
  signer = accounts[0].address;
  console.log("signer address:%s", signer);
  await verifyPool();
};


async function verifyPool() {
  await hre.run("verify:verify", {
    address: pool,
    contract: "contracts/core/MultiSigPool.sol:MultiSigPool",
    constructorArguments: [
      signers,
      usdcAddress,
      oneInchAddress,
      starkEx,
      factAddress,
      assetType,
    ],
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
