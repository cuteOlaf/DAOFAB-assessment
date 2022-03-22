const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DFGlobalEscrow", function () {
  let escrow, escrowAddress;
  let owner, ownerSigner;
  let sender, recipient, agent, delegator, other;
  let senderSigner, recipientSigner, agentSigner, delegatorSigner, otherSigner;
  let signers, accounts;

  const ESCROW_ETHER = "escrow_ether";
  const ETHER_AMOUNT = ethers.utils.parseEther("0.00001");
  const ESCROW_ERC20 = "escrow_erc20";
  const ERC20_AMOUNT = 20000;
  const DAI_CONTRACT = "0x6b175474e89094c44da98b954eedeac495271d0f";
  const CDAI_CONTRACT = "0x54afeb96c4521c36fb06d9d7788d14eaa7f15b73";
  const CETHER_CONTRACT = "0x4d5a960e42de4e9d9ab9d56c6d28ad024eb11b25";

  before(async function () {
    const DFGlobalEscrow = await ethers.getContractFactory("DFGlobalEscrow");
    escrow = await DFGlobalEscrow.deploy();

    await escrow.deployed();
    escrowAddress = escrow.address;

    // // console.log("escrow address: ", escrowAddress);

    signers = await ethers.getSigners();
    accounts = signers.map((signer) => signer.address);

    [
      ownerSigner,
      senderSigner,
      recipientSigner,
      agentSigner,
      delegatorSigner,
      otherSigner,
    ] = signers;
    [owner, sender, recipient, agent, delegator, other] = accounts;
  });

  describe("test - createEscrow", function () {
    it("eligible parties", async function () {
      // console.log("eligible parties");
      await escrow
        .connect(senderSigner)
        .createEscrow(
          ESCROW_ETHER,
          sender,
          recipient,
          agent,
          0,
          ethers.constants.AddressZero,
          CETHER_CONTRACT,
          ETHER_AMOUNT,
          false
        );

      await escrow
        .connect(delegatorSigner)
        .createEscrow(
          ESCROW_ERC20,
          sender,
          recipient,
          agent,
          1,
          DAI_CONTRACT,
          CDAI_CONTRACT,
          ERC20_AMOUNT,
          false
        );
    });

    describe("invalid parties", function () {
      // console.log("invalid parties");
      it("zero addresses", async function () {
        // console.log("zero addresses");
        expect(
          escrow.createEscrow(
            "zero parties",
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            0,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            1000,
            true
          )
        ).to.be.reverted;
      });
      it("duplicated escrow", async function () {
        // console.log("duplicated escrow");
        await escrow.createEscrow(
          "duplicate",
          sender,
          recipient,
          agent,
          0,
          ethers.constants.AddressZero,
          CETHER_CONTRACT,
          111,
          true
        );

        expect(
          escrow.createEscrow(
            "duplicate",
            sender,
            recipient,
            agent,
            0,
            ethers.constants.AddressZero,
            CETHER_CONTRACT,
            111,
            true
          )
        ).to.be.reverted;
      });
      it("invalid delegators", async function () {
        // console.log("invalid delegators");
        expect(
          escrow
            .connect(recipientSigner)
            .createEscrow(
              "invalid delegator",
              sender,
              recipient,
              agent,
              0,
              ethers.constants.AddressZero,
              CETHER_CONTRACT,
              1000,
              false
            )
        ).to.be.reverted;
      });
    });
  });

  describe("test - fund", function () {
    describe("caller check", function () {
      it("sender can call this function", async function () {
        await escrow
          .connect(senderSigner)
          .fund(ESCROW_ETHER, 0, { value: ETHER_AMOUNT });
      });
      // it("delegator can call this function", async function () {
      //   await escrow.connect(delegatorSigner).fund(ESCROW_ERC20, ERC20_AMOUNT);
      // });
      it("recipient cannot call this function - no delegator", async function () {
        expect(escrow.connect(recipientSigner).fund(ESCROW_ETHER, ETHER_AMOUNT))
          .to.be.reverted;
      });
      it("recipient cannot call this function - delegator", async function () {
        expect(escrow.connect(recipientSigner).fund(ESCROW_ERC20, ERC20_AMOUNT))
          .to.be.reverted;
      });
    });
    describe("amount check", function () {});
  });

  describe("test - release", function () {
    it("successful release - sender, agent", async function () {
      await escrow.connect(senderSigner).release(ESCROW_ETHER, sender);
      await escrow.connect(recipientSigner).release(ESCROW_ETHER, recipient);
    });
    it("invalid release - duplicate call from the same user", async function () {
      await escrow.connect(senderSigner).release(ESCROW_ERC20, sender);
      expect(escrow.connect(senderSigner).release(ESCROW_ERC20, sender)).to.be
        .reverted;
    });
    it("invalid release - invalid party - not signable user", async function () {
      expect(escrow.connect(otherSigner).release(ESCROW_ERC20, other)).to.be
        .reverted;
    });
  });
});
