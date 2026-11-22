#!/usr/bin/env node
"use strict";

// Emulator-only, repeatable demo monitoring dataset. Never reads .firebaserc.
process.env.TZ = "Asia/Makassar";

const net = require("node:net");
const path = require("node:path");
const {createRequire} = require("node:module");

const PROJECT_ID = "demo-tb-monitoring";
const AUTH_HOST = "127.0.0.1:9199";
const FIRESTORE_HOST = "127.0.0.1:8180";
const HUB_HOST = "127.0.0.1:4400";
const FUNCTION_HOST = "127.0.0.1:5101";
const adminRequire = createRequire(path.resolve(__dirname, "..", "functions", "package.json"));
const {initializeApp, getApps} = adminRequire("firebase-admin/app");
const {getAuth} = adminRequire("firebase-admin/auth");
const {getFirestore, FieldValue, Timestamp} = adminRequire("firebase-admin/firestore");

const caregiverFor = (patientNumber) => patientNumber <= 8 ? 1 : 2;
const patientUid = (n) => `demo_patient_${String(n).padStart(2, "0")}`;
const caregiverUid = (n) => `demo_caregiver_${String(n).padStart(2, "0")}`;
const targetDates = {
  1: "2026-11-17",
  2: "2026-05-17", 3: "2026-05-17", 4: "2026-05-17",
  5: "2026-08-17", 6: "2026-08-17", 7: "2026-07-17",
  8: "2026-09-17", 9: "2026-05-17", 10: "2026-05-17",
  11: "2026-05-17", 12: "2026-05-17", 13: "2026-05-17",
  14: "2026-05-17", 15: "2026-06-17",
};
const examinations = {
  7: {initial: "positive", month_2: "negative"},
  9: {initial: "negative", month_2: "negative", pre_final: "negative", final: "negative"},
  10: {initial: "positive", month_2: "negative", pre_final: "negative", final: "negative"},
  11: {initial: "positive", month_2: "positive", pre_final: "positive", final: "positive"},
  12: {initial: "positive", month_2: "negative", pre_final: "positive"},
  13: {initial: "positive", month_2: "positive"},
  14: {initial: "negative", month_2: "negative", pre_final: "negative", final: "negative"},
  15: {initial: "positive", month_2: "positive", pre_final: "negative"},
};
const completionPatients = new Set([9, 10, 11, 12, 14]);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function localDate(iso, hour = 0, minute = 0) {
  const [year, month, day] = iso.split("-").map(Number);
  return new Date(year, month - 1, day, hour, minute, 0, 0);
}

function addMonthsClamped(date, count) {
  const first = new Date(date.getFullYear(), date.getMonth() + count, 1);
  const lastDay = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate();
  return new Date(first.getFullYear(), first.getMonth(), Math.min(date.getDate(), lastDay));
}

function key(date) {
  return `${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, "0")}${String(date.getDate()).padStart(2, "0")}`;
}

function scheduledDays(start) {
  const intensiveEnd = addMonthsClamped(start, 2);
  const end = addMonthsClamped(start, 6);
  const days = [];
  for (let date = new Date(start); date < end; date.setDate(date.getDate() + 1)) {
    const intensive = date < intensiveEnd;
    const weekday = date.getDay(); // Sunday=0; Mon/Wed/Fri = 1/3/5.
    if (intensive || [1, 3, 5].includes(weekday)) days.push(new Date(date));
  }
  return days;
}

function timestamp(date) {
  return Timestamp.fromDate(date);
}

async function portOpen(host, port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({host, port});
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("Could not safely verify the Functions Emulator endpoint."));
    }, 1500);
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

async function verifyEmulator() {
  assert(process.env.GCLOUD_PROJECT === PROJECT_ID &&
    process.env.GOOGLE_CLOUD_PROJECT === PROJECT_ID,
  "Set both GCLOUD_PROJECT and GOOGLE_CLOUD_PROJECT to demo-tb-monitoring.");
  assert(process.env.FIREBASE_AUTH_EMULATOR_HOST === AUTH_HOST,
    `FIREBASE_AUTH_EMULATOR_HOST must be ${AUTH_HOST}.`);
  assert(process.env.FIRESTORE_EMULATOR_HOST === FIRESTORE_HOST,
    `FIRESTORE_EMULATOR_HOST must be ${FIRESTORE_HOST}.`);
  assert(process.env.FIREBASE_CONFIG &&
    JSON.parse(process.env.FIREBASE_CONFIG).projectId === PROJECT_ID,
  "FIREBASE_CONFIG must explicitly name demo-tb-monitoring.");

  const auth = await fetch(`http://${AUTH_HOST}/emulator/v1/projects/${PROJECT_ID}/config`);
  assert(auth.ok, "Expected Firebase Authentication Emulator did not confirm this project.");
  assert((await fetch(`http://${FIRESTORE_HOST}/`)).ok,
    "Expected Firestore Emulator is unavailable.");
  const hubResponse = await fetch(`http://${HUB_HOST}/emulators`);
  assert(hubResponse.ok, "Expected Firebase Emulator Hub is unavailable.");
  const hub = await hubResponse.json();
  assert(hub.auth?.host === "127.0.0.1" && hub.auth?.port === 9199 &&
    hub.firestore?.host === "127.0.0.1" && hub.firestore?.port === 8180,
  "Hub endpoints do not match the required loopback emulators.");
  assert(hub.functions?.host === "127.0.0.1" && hub.functions?.port === 5101,
    "Functions Emulator must be the configured loopback endpoint.");
  assert(await portOpen("127.0.0.1", 5101),
    "Functions Emulator endpoint is not listening as reported by the Hub.");
}

async function verifiedDemoUsers(auth, db) {
  const people = [];
  for (let n = 1; n <= 2; n++) people.push({uid: caregiverUid(n), role: "caregiver"});
  for (let n = 1; n <= 15; n++) people.push({uid: patientUid(n), role: "patient", number: n});
  for (const person of people) {
    const [account, profile] = await Promise.all([
      auth.getUser(person.uid), db.collection("users").doc(person.uid).get(),
    ]);
    assert(account.customClaims?.isDemo === true,
      `Auth claim isDemo is missing for ${person.uid}; no writes performed.`);
    assert(profile.exists && profile.data().isDemo === true &&
      profile.data().role === person.role,
    `Demo profile/role verification failed for ${person.uid}; no writes performed.`);
    if (person.role === "patient") {
      assert(profile.data().patientCode === `DMPA${String(person.number).padStart(4, "0")}`,
        `Patient code mismatch for ${person.uid}; no writes performed.`);
    }
  }
  return people;
}

function expectedDose(patientNo, dayIndex) {
  if (patientNo === 3) return dayIndex % 10 === 0 ? "missed" : "taken"; // 90%
  if (patientNo === 4) return dayIndex % 10 < 3 ? "missed" : "taken"; // 70%
  if (patientNo === 5) return "late"; // lateness is confirmed adherence.
  if (patientNo === 6) return dayIndex % 4 === 0 ? "missed" : "taken";
  if (patientNo === 15) return dayIndex % 7 === 0 ? "missed" : dayIndex % 3 === 0 ? "late" : "taken";
  return "taken";
}

function sameTimestamp(value, expected) {
  return value instanceof Timestamp && value.toMillis() === expected.toMillis();
}

function sameDose(data, expected) {
  return data.patientId === expected.patientId && data.caregiverId === expected.caregiverId &&
    data.name === expected.name && data.dosage === expected.dosage &&
    data.treatmentGroup === expected.treatmentGroup && data.treatmentDay === expected.treatmentDay &&
    data.systemGenerated === true && data.status === expected.status &&
    data.scheduleRevision === 1 && sameTimestamp(data.scheduledAt, expected.scheduledAt) &&
    data.responseAction === expected.responseAction;
}

function sameLog(data, expected) {
  return data.medicineId === expected.medicineId && data.patientId === expected.patientId &&
    data.name === expected.name && data.dosage === expected.dosage &&
    data.status === expected.status && data.responseAction === expected.responseAction &&
    sameTimestamp(data.scheduledAt, expected.scheduledAt);
}

async function applyChunks(db, operations, stats) {
  for (let offset = 0; offset < operations.length; offset += 400) {
    // Recheck destination identity immediately before every batch commit.
    assert(process.env.GCLOUD_PROJECT === PROJECT_ID &&
      process.env.GOOGLE_CLOUD_PROJECT === PROJECT_ID &&
      process.env.FIREBASE_AUTH_EMULATOR_HOST === AUTH_HOST &&
      process.env.FIRESTORE_EMULATOR_HOST === FIRESTORE_HOST,
    "Emulator target changed; stopping before next write batch.");
    const batch = db.batch();
    for (const operation of operations.slice(offset, offset + 400)) operation(batch);
    await batch.commit();
    stats.batches++;
  }
}

async function main() {
  await verifyEmulator();
  if (!getApps().length) initializeApp({projectId: PROJECT_ID});
  const auth = getAuth();
  const db = getFirestore();
  await verifiedDemoUsers(auth, db); // all identities verified before any write.

  const before = {};
  for (const name of ["users", "patientCodes", "pairings", "treatments", "btaExaminations", "medicines", "medicationLogs", "notifications", "pushOutbox"]) {
    before[name] = (await db.collection(name).get()).size;
  }
  assert(before.users === 17 && before.patientCodes === 15 &&
    before.treatments === 15 && before.btaExaminations === 60,
  "Expected demo account/treatment/BTA collection counts changed; no writes performed.");

  const stats = {batches: 0, pairingsCreated: 0, profilesUpdated: 0, treatmentsUpdated: 0,
    btaUpdated: 0, medicinesCreated: 0, logsCreated: 0, logStatus: {taken: 0, late: 0, missed: 0}};
  const pairingOps = [];
  const profileOps = [];
  const treatmentOps = [];
  const btaOps = [];
  const medicineOps = [];
  const logOps = [];

  for (let n = 1; n <= 15; n++) {
    const uid = patientUid(n);
    const caregiverId = caregiverUid(caregiverFor(n));
    const patientRef = db.collection("users").doc(uid);
    const patient = (await patientRef.get()).data();
    const code = patient.patientCode;
    const pairingId = `${caregiverId}_${uid}`;
    const pairingRef = db.collection("pairings").doc(pairingId);
    const pairing = await pairingRef.get();
    const pairingData = {caregiverId, patientId: uid, patientName: patient.fullName || `Pasien Demo ${String(n).padStart(2, "0")}`, invitationCode: code};
    if (pairing.exists) {
      const current = pairing.data();
      assert(current.caregiverId === pairingData.caregiverId && current.patientId === uid &&
        current.invitationCode === code,
      `Pairing ID collision at ${pairingId}; stopping.`);
    } else {
      pairingOps.push((batch) => batch.set(pairingRef, {...pairingData, createdAt: FieldValue.serverTimestamp()}));
      stats.pairingsCreated++;
    }

    const start = localDate(targetDates[n]);
    const startTs = timestamp(start);
    const completion = addMonthsClamped(start, 6);
    const completionTs = timestamp(completion);
    const profileChanges = !sameTimestamp(patient.treatmentStartedAt, startTs) ||
      patient.medicationHour !== 8 || patient.medicationMinute !== 0;
    if (profileChanges) {
      profileOps.push((batch) => batch.update(patientRef, {
        treatmentStartedAt: startTs, medicationHour: 8, medicationMinute: 0,
        medicationTimeUpdatedBy: caregiverId, medicationTimeUpdatedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }));
      stats.profilesUpdated++;
    }

    const treatmentRef = db.collection("treatments").doc(uid);
    const treatmentSnap = await treatmentRef.get();
    assert(treatmentSnap.exists && treatmentSnap.data().patientId === uid,
      `Existing treatment missing or linked incorrectly for ${uid}; stopping.`);
    const treatmentStatus = completionPatients.has(n) ? "completed" : "ongoing";
    const failureType = n === 13 ? "persistent_bacteriological_failure" : "none";
    const treatment = treatmentSnap.data();
    const treatmentChanges = !sameTimestamp(treatment.treatmentStartDate, startTs) ||
      !sameTimestamp(treatment.expectedCompletionDate, completionTs) ||
      treatment.status !== treatmentStatus || treatment.confirmedFailureType !== failureType ||
      (treatmentStatus === "completed" && !sameTimestamp(treatment.actualCompletionDate, completionTs));
    if (treatmentChanges) {
      treatmentOps.push((batch) => batch.update(treatmentRef, {
        treatmentStartDate: startTs, expectedCompletionDate: completionTs,
        actualCompletionDate: treatmentStatus === "completed" ? completionTs : null,
        status: treatmentStatus, confirmedFailureType: failureType,
        failureNotes: n === 13 ? "Kegagalan terkonfirmasi untuk skenario demonstrasi." : "",
        updatedAt: FieldValue.serverTimestamp(),
      }));
      stats.treatmentsUpdated++;
    }

    const btaTypes = ["initial", "month_2", "pre_final", "final"];
    const btaDates = [start, addMonthsClamped(start, 2), addMonthsClamped(start, 4), addMonthsClamped(start, 5)];
    for (let i = 0; i < btaTypes.length; i++) {
      const suffix = ["initial", "month2", "pre_final", "final"][i];
      const ref = db.collection("btaExaminations").doc(`bta_${uid}_${suffix}`);
      const snap = await ref.get();
      assert(snap.exists && snap.data().patientId === uid,
        `Existing BTA schedule missing/linked incorrectly (${ref.id}); stopping.`);
      const desiredResult = examinations[n]?.[btaTypes[i]] ?? null;
      const examDate = desiredResult ? new Date(btaDates[i].getFullYear(), btaDates[i].getMonth(), btaDates[i].getDate(), 10) : null;
      const data = snap.data();
      const changed = data.examinationType !== btaTypes[i] || !sameTimestamp(data.scheduledDate, timestamp(btaDates[i])) ||
        data.result !== desiredResult || (desiredResult && !sameTimestamp(data.examinationDate, timestamp(examDate))) ||
        (desiredResult && data.enteredByCaregiver !== caregiverId) ||
        (desiredResult && data.notes !== "Hasil pemeriksaan data demonstrasi.");
      if (changed) {
        const update = {examinationType: btaTypes[i], scheduledDate: timestamp(btaDates[i]), updatedAt: FieldValue.serverTimestamp()};
        if (desiredResult) Object.assign(update, {
          result: desiredResult, examinationDate: timestamp(examDate),
          enteredByCaregiver: caregiverId, notes: "Hasil pemeriksaan data demonstrasi.",
        });
        btaOps.push((batch) => batch.update(ref, update));
        stats.btaUpdated++;
      }
    }

    let dayIndex = 0;
    const todayLocal = localDate("2026-11-17", 23, 59);
    for (const day of scheduledDays(start)) {
      const scheduledAt = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 8, 0);
      const isDue = scheduledAt <= todayLocal;
      const id = `auto_${uid}_${key(day)}`;
      const medicineRef = db.collection("medicines").doc(id);
      const [medicineSnap, logSnap] = await Promise.all([
        medicineRef.get(), db.collection("medicationLogs").doc(id).get(),
      ]);
      const status = isDue ? expectedDose(n, dayIndex) : "pending";
      const responseAction = status === "missed" ? "automatic_missed" : status === "pending" ? null : "taken";
      const respondedAt = status === "missed" ? new Date(scheduledAt.getTime() + 19 * 60 * 60 * 1000) :
        status === "late" ? new Date(scheduledAt.getTime() + 60 * 60 * 1000) :
        status === "taken" ? new Date(scheduledAt.getTime() + 5 * 60 * 1000) : null;
      const expected = {
        patientId: uid, caregiverId, name: "MINUM OBAT", dosage: "Sesuai resep",
        scheduledAt: timestamp(scheduledAt), treatmentGroup: "group1", treatmentDay: key(day),
        systemGenerated: true, status, scheduleRevision: 1, responseAction,
      };
      if (medicineSnap.exists) {
        assert(medicineSnap.data().patientId === uid && medicineSnap.data().systemGenerated === true,
          `Medicine ID collision/non-demo document ${id}; stopping.`);
        assert(sameDose(medicineSnap.data(), expected),
          `Existing medicine differs from deterministic demo schedule: ${id}; stopping to preserve it.`);
      } else {
        const dose = {
          caregiverId, patientId: uid, name: "MINUM OBAT", dosage: "Sesuai resep",
          scheduledAt: timestamp(scheduledAt), treatmentGroup: "group1", treatmentDay: key(day),
          systemGenerated: true, status, scheduleRevision: 1, alarmState: status === "pending" ? "scheduled" : "stopped",
          reminderTriggeredAt: null, deviceTriggeredAt: null, deviceTriggerPushedAt: null,
          dueNotifiedAt: null, lateNotifiedAt: null, snoozedUntil: null, dismissedAt: null,
          responseAction, createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
        };
        if (status === "taken" || status === "late") Object.assign(dose, {takenAt: timestamp(respondedAt), respondedAt: timestamp(respondedAt)});
        if (status === "missed") Object.assign(dose, {missedAt: timestamp(respondedAt), respondedAt: timestamp(respondedAt)});
        medicineOps.push((batch) => batch.create(medicineRef, dose));
        stats.medicinesCreated++;
      }
      if (status !== "pending") {
        const logRef = db.collection("medicationLogs").doc(id);
        const log = {
          medicineId: id, patientId: uid, name: "MINUM OBAT", dosage: "Sesuai resep",
          scheduledAt: timestamp(scheduledAt), status, responseAction,
          takenAt: status === "taken" || status === "late" ? timestamp(respondedAt) : null,
          missedAt: status === "missed" ? timestamp(respondedAt) : null,
          respondedAt: timestamp(respondedAt), recordedAt: timestamp(respondedAt),
          scheduleRevision: 1,
        };
        if (logSnap.exists) {
          assert(logSnap.data().patientId === uid && sameLog(logSnap.data(), log),
            `Existing medication log conflicts with deterministic demo history: ${id}; stopping.`);
        } else {
          logOps.push((batch) => batch.create(logRef, log));
          stats.logsCreated++;
          stats.logStatus[status]++;
        }
      } else {
        assert(!logSnap.exists || logSnap.data().patientId === uid,
          `Unexpected future-dose log collision ${id}; stopping.`);
      }
      if (isDue) dayIndex++;
    }
  }

  // Recheck every patient's demo markers immediately before first writes.
  await verifiedDemoUsers(auth, db);
  for (const [ops, label] of [
    [pairingOps, "pairings"], [profileOps, "profiles"], [treatmentOps, "treatments"],
    [btaOps, "BTA"], [medicineOps, "medicines"], [logOps, "medication logs"],
  ]) {
    console.log(`Writing ${ops.length} ${label} changes in emulator batches.`);
    await applyChunks(db, ops, stats);
  }

  console.log(JSON.stringify({projectId: PROJECT_ID, timezone: "Asia/Makassar", before, stats,
    expectedSchedules: 1704, expectedDueLogs: 1425}, null, 2));
}

main().catch((error) => {
  console.error(`Demo seeder stopped: ${error.message}`);
  process.exitCode = 1;
});
