#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const {createRequire} = require("node:module");

const PROJECT_ID = process.env.DEMO_PROJECT_ID || "demo-tb-monitoring";
const AUTH_HOST = process.env.DEMO_AUTH_EMULATOR_HOST || "127.0.0.1:9199";
const FIRESTORE_HOST = process.env.DEMO_FIRESTORE_EMULATOR_HOST || "127.0.0.1:8180";
const HUB_HOST = process.env.DEMO_EMULATOR_HUB_HOST || "127.0.0.1:4400";
const HUB_URL = "http://" + HUB_HOST + "/emulators";
const CREDENTIALS_FILE = path.resolve(__dirname, "..", ".demo_accounts.local.json");
const adminRequire = createRequire(path.resolve(__dirname, "..", "functions", "package.json"));
const {initializeApp, getApps} = adminRequire("firebase-admin/app");
const {getAuth} = adminRequire("firebase-admin/auth");
const {getFirestore, FieldValue} = adminRequire("firebase-admin/firestore");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function verifyEmulators() {
  assert(/^demo-[a-z0-9-]+$/.test(PROJECT_ID),
    "The project must use a demo-* ID.");
  assert(/^127\.0\.0\.1:\d{2,5}$/.test(AUTH_HOST) &&
      /^127\.0\.0\.1:\d{2,5}$/.test(FIRESTORE_HOST) &&
      /^127\.0\.0\.1:\d{2,5}$/.test(HUB_HOST),
    "Only loopback emulator endpoints are allowed.");
  assert(process.env.FIREBASE_AUTH_EMULATOR_HOST === AUTH_HOST,
    `Set FIREBASE_AUTH_EMULATOR_HOST=${AUTH_HOST}; refusing any other target.`);
  assert(process.env.FIRESTORE_EMULATOR_HOST === FIRESTORE_HOST,
    `Set FIRESTORE_EMULATOR_HOST=${FIRESTORE_HOST}; refusing any other target.`);
  assert(process.env.GCLOUD_PROJECT === PROJECT_ID || process.env.FIREBASE_PROJECT_ID === PROJECT_ID,
    `Set GCLOUD_PROJECT=${PROJECT_ID}; refusing any other project.`);

  const auth = await fetch(`http://${AUTH_HOST}/emulator/v1/projects/${PROJECT_ID}/config`);
  assert(auth.ok, "Firebase Auth Emulator did not confirm the demo project.");
  const firestore = await fetch(`http://${FIRESTORE_HOST}/`);
  assert(firestore.ok, "Firestore Emulator is not reachable at the expected endpoint.");
  const hubResponse = await fetch(HUB_URL);
  assert(hubResponse.ok, "Firebase Emulator Hub is not reachable.");
  const emulators = await hubResponse.json();
  assert(emulators.auth?.port === Number(AUTH_HOST.split(":").at(-1)) && emulators.firestore?.port === Number(FIRESTORE_HOST.split(":").at(-1)),
    "Emulator Hub ports do not match the expected demo ports.");
  if (emulators.functions?.port) {
    const host = emulators.functions.host || "127.0.0.1";
    assert(["127.0.0.1", "localhost", "::1"].includes(host),
      "Functions endpoint is not loopback; refusing to continue.");
    const listening = await isPortListening(host, emulators.functions.port);
    assert(!listening,
      "Functions Emulator is active. Stop it before seeding so patient-profile triggers cannot create medical records.");
  }
}

function isPortListening(host, port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({host, port});
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("Could not safely determine whether Functions Emulator is active."));
    }, 1500);
    timeout.unref();
    socket.once("connect", () => {
      clearTimeout(timeout);
      socket.destroy();
      resolve(true);
    });
    socket.once("error", (error) => {
      clearTimeout(timeout);
      if (error.code === "ECONNREFUSED") resolve(false);
      else reject(error);
    });
  });
}

function validateCredentials(config) {
  assert(typeof config.password === "string" && config.password.length >= 12,
    "Local demo password must be at least 12 characters.");
  assert(config.caregivers?.length === 2 && config.patients?.length === 15,
    "Expected exactly two caregiver and fifteen patient demo accounts.");
  for (const [role, records] of [["caregiver", config.caregivers], ["patient", config.patients]]) {
    records.forEach((record, index) => {
      const expected = role === "caregiver" ? "pendamping" : "pasien";
      const expectedNumber = String(index + 1).padStart(2, "0");
      assert(record.email === `demo.${expected}${expectedNumber}@example.test`,
        `Unexpected ${role} email at index ${index}.`);
      assert(typeof record.name === "string" && record.name.trim().length > 0,
        `Missing display name for ${record.email}.`);
    });
  }
}

async function ensureAccount(auth, db, record, role, index, password) {
  const kind = role === "caregiver" ? "caregiver" : "patient";
  const uid = `demo_${kind}_${String(index + 1).padStart(2, "0")}`;
  let user;
  try {
    user = await auth.getUser(uid);
    assert(user.email === record.email,
      `UID ${uid} is already assigned to a different email; refusing to modify it.`);
    await auth.updateUser(uid, {
      email: record.email,
      password,
      displayName: record.name,
      emailVerified: true,
    });
  } catch (error) {
    if (error.code !== "auth/user-not-found") throw error;
    user = await auth.createUser({
      uid,
      email: record.email,
      password,
      displayName: record.name,
      emailVerified: true,
    });
  }

  await auth.setCustomUserClaims(user.uid, {
    ...(user.customClaims || {}),
    isDemo: true,
  });

  const userRef = db.collection("users").doc(uid);
  const existing = await userRef.get();
  const prior = existing.data() || {};
  if (existing.exists) {
    assert(prior.email === record.email && prior.role === role,
      `Existing profile ${uid} is not this demo identity; refusing to overwrite it.`);
  }

  const profile = {
    fullName: record.name,
    email: record.email,
    phoneNumber: `08${String(1000000000 + (role === "patient" ? 100 + index : index)).slice(-10)}`,
    role,
    isDemo: true,
    notificationsEnabled: true,
    createdAt: prior.createdAt || FieldValue.serverTimestamp(),
  };

  if (role === "patient") {
    const patientCode = `DMPA${String(index + 1).padStart(4, "0")}`;
    profile.patientCode = patientCode;
    profile.age = 24 + index;
    profile.ageCategory = "Dewasa";
    profile.gender = index % 2 === 0 ? "female" : "male";
    profile.treatmentGroup = "group1";
    profile.treatmentStartedAt = prior.treatmentStartedAt || FieldValue.serverTimestamp();
    const codeRef = db.collection("patientCodes").doc(patientCode);
    const codeSnapshot = await codeRef.get();
    if (codeSnapshot.exists) {
      assert(codeSnapshot.data().patientId === uid,
        `Patient code ${patientCode} belongs to a different account; refusing to overwrite it.`);
    } else {
      await codeRef.create({
        patientId: uid,
        patientName: record.name,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
  }

  await userRef.set(profile, {merge: true});
  return {uid: user.uid, email: record.email, role, profile: "present"};
}

async function main() {
  assert(fs.existsSync(CREDENTIALS_FILE),
    `Create the ignored local credential file first: ${CREDENTIALS_FILE}`);
  const config = JSON.parse(fs.readFileSync(CREDENTIALS_FILE, "utf8"));
  validateCredentials(config);
  await verifyEmulators();

  process.env.GCLOUD_PROJECT = PROJECT_ID;
  process.env.GOOGLE_CLOUD_PROJECT = PROJECT_ID;
  if (getApps().length === 0) initializeApp({projectId: PROJECT_ID});
  const auth = getAuth();
  const db = getFirestore();
  const results = [];
  for (let index = 0; index < config.caregivers.length; index++) {
    results.push(await ensureAccount(auth, db, config.caregivers[index], "caregiver", index, config.password));
  }
  for (let index = 0; index < config.patients.length; index++) {
    results.push(await ensureAccount(auth, db, config.patients[index], "patient", index, config.password));
  }

  console.log(JSON.stringify({projectId: PROJECT_ID, count: results.length, accounts: results}, null, 2));
}

main().catch((error) => {
  console.error(`Demo account seeding stopped: ${error.message}`);
  process.exitCode = 1;
});
