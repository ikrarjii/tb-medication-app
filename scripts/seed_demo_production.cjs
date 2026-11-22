#!/usr/bin/env node
"use strict";

// Production-only demo seeder. Dry-run is the default; use --apply to write.
// Never point this script at an emulator or a project other than the constant below.
const fs = require("node:fs");
const path = require("node:path");
const {createRequire} = require("node:module");
const {randomBytes} = require("node:crypto");

const PROJECT_ID = "drugcontrol-a35e2";
const ROOT = path.resolve(__dirname, "..");
const LOCAL_CREDENTIALS = path.join(ROOT, ".demo_production_credentials.local.json");
const adminRequire = createRequire(path.join(ROOT, "functions", "package.json"));
const {applicationDefault, initializeApp, getApps} = adminRequire("firebase-admin/app");
const {getAuth} = adminRequire("firebase-admin/auth");
const {getFirestore, FieldValue, Timestamp} = adminRequire("firebase-admin/firestore");

const patientCases = [
  {n: 1, caregiver: 1, outcome: "CURED", status: "completed", results: ["positive", "negative", "negative", "negative"]},
  {n: 2, caregiver: 1, outcome: "TREATMENT COMPLETED", status: "completed", results: ["negative", "negative", "negative", "negative"]},
  {n: 3, caregiver: 1, outcome: "FAILED", status: "ongoing", failure: true, results: ["positive", "positive", "positive", "positive"]},
  {n: 4, caregiver: 1, outcome: "TREATMENT IN PROGRESS", status: "ongoing", results: ["positive", "positive", null, null]},
  {n: 5, caregiver: 2, outcome: "TREATMENT IN PROGRESS", status: "ongoing", results: ["positive", "negative", null, null]},
  {n: 6, caregiver: 2, outcome: "TREATMENT IN PROGRESS", status: "ongoing", results: ["positive", "negative", "positive", null]},
  {n: 7, caregiver: 2, outcome: "FAILED", status: "ongoing", confirmedReversal: true, results: ["positive", "negative", "positive", null], confirmation: "positive"},
  {n: 8, caregiver: 2, outcome: "TREATMENT IN PROGRESS", status: "ongoing", results: [null, null, null, null]},
];
const btaTypes = ["initial", "month_2", "pre_final", "final"];
const uid = (role, n) => `demo_${role}_${String(n).padStart(2, "0")}`;
const email = (role, n) => `demo.${role === "caregiver" ? "pendamping" : "pasien"}${String(n).padStart(2, "0")}@example.test`;
const patientName = (n) => `Pasien Demo ${String(n).padStart(2, "0")}`;
const caregiverName = (n) => `Pengawas Demo ${String(n).padStart(2, "0")}`;
const patientCode = (n) => `DMPA${String(n).padStart(4, "0")}`;
const day = (value) => new Date(Date.UTC(value.getUTCFullYear(), value.getUTCMonth(), value.getUTCDate()));
const addMonths = (date, count) => {
  const y = date.getUTCFullYear();
  const m = date.getUTCMonth() + count;
  const target = new Date(Date.UTC(y, m, 1));
  const last = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(date.getUTCDate(), last));
  return target;
};
const atHour = (date, hour = 8) => new Date(date.getTime() + hour * 3600000);
const dayKey = (date) => `${date.getUTCFullYear()}${String(date.getUTCMonth() + 1).padStart(2, "0")}${String(date.getUTCDate()).padStart(2, "0")}`;
const ts = (date) => Timestamp.fromDate(date);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseArgs() {
  const apply = process.argv.includes("--apply");
  const allowed = new Set(["--apply", "--dry-run"]);
  for (const arg of process.argv.slice(2)) assert(allowed.has(arg), `Unknown argument ${arg}`);
  assert(!(apply && process.argv.includes("--dry-run")), "Choose only one mode.");
  return {apply};
}

function baseTreatment(caseInfo, start, completion) {
  const exams = [];
  for (let i = 0; i < 4; i++) {
    const result = caseInfo.results[i];
    if (result) exams.push({examinationType: btaTypes[i], result, examinationDate: atHour(addMonths(start, [0, 2, 4, 5][i]), 10)});
  }
  if (caseInfo.confirmation) exams.push({examinationType: "confirmation", result: caseInfo.confirmation, examinationDate: atHour(addMonths(start, 5), 12)});
  const valid = exams.slice().sort((a, b) => a.examinationDate - b.examinationDate);
  let positiveSeen = false;
  let conversionIndex = null;
  valid.forEach((exam, i) => {
    if (conversionIndex !== null) return;
    if (exam.result === "positive") positiveSeen = true;
    if (positiveSeen && exam.result === "negative") conversionIndex = i;
  });
  let possibleReversal = false;
  let confirmedReversal = false;
  if (conversionIndex !== null) {
    let positiveAfterConversion = false;
    for (let i = conversionIndex + 1; i < valid.length; i++) {
      if (valid[i].result !== "positive") continue;
      if (positiveAfterConversion && valid[i].examinationType === "confirmation") {
        confirmedReversal = true;
        possibleReversal = true;
        break;
      }
      positiveAfterConversion = true;
      possibleReversal = true;
    }
  }
  const confirmedFailure = Boolean(caseInfo.failure || confirmedReversal);
  const conversionDetected = conversionIndex !== null;
  const initialPositive = exams.find((x) => x.examinationType === "initial")?.result === "positive";
  const finalNegative = exams.find((x) => x.examinationType === "final")?.result === "negative";
  const path = [`Treatment completed? ${caseInfo.status === "completed" ? "YES" : "NO"}`];
  let calculated;
  if (caseInfo.status !== "completed") {
    path.push(`Confirmed treatment failure? ${confirmedFailure ? "YES" : "NO"}`);
    calculated = confirmedFailure ? "FAILED" : "TREATMENT IN PROGRESS";
  } else if (initialPositive) {
    path.push("Initial BTA positive? YES", `BTA conversion detected? ${conversionDetected ? "YES" : "NO"}`);
    if (conversionDetected) {
      path.push(`Confirmed bacteriological reversal? ${confirmedReversal ? "YES" : "NO"}`);
      if (confirmedReversal) calculated = "FAILED";
      else if (finalNegative) {
        path.push("Final BTA negative? YES", "Confirmed treatment failure? NO");
        calculated = "CURED";
      }
    }
    if (!calculated) {
      path.push(`Confirmed treatment failure? ${confirmedFailure ? "YES" : "NO"}`);
      calculated = confirmedFailure ? "FAILED" : "TREATMENT COMPLETED";
    }
  } else {
    path.push(`Initial BTA positive? ${initialPositive ? "YES" : "NO"}`, `Confirmed treatment failure? ${confirmedFailure ? "YES" : "NO"}`);
    calculated = confirmedFailure ? "FAILED" : "TREATMENT COMPLETED";
  }
  path.push(`Final classification: ${calculated}`);
  assert(calculated === caseInfo.outcome, `Internal case classification mismatch for patient ${caseInfo.n}: ${calculated}`);
  return {confirmedFailure, conversionDetected, possibleReversal, confirmedReversal, path};
}

function syntheticPassword() {
  // High-entropy base64url passwords, one per account.
  return `D3mo-${randomBytes(18).toString("base64url")}-aA9!`;
}

function buildManifest() {
  const now = day(new Date());
  const startDates = {
    1: [2026, 0, 17], 2: [2026, 2, 17], 3: [2026, 5, 17],
    4: [2026, 8, 17], 5: [2026, 6, 17], 6: [2026, 5, 17],
    7: [2026, 4, 17], 8: [2026, 9, 17],
  };
  return patientCases.map((c) => {
    const start = new Date(Date.UTC(...startDates[c.n]));
    const completion = addMonths(start, 6);
    return {...c, start, completion, now, treatment: baseTreatment(c, start, completion)};
  });
}

async function assertDestination(apply) {
  assert(!process.env.FIREBASE_AUTH_EMULATOR_HOST && !process.env.FIRESTORE_EMULATOR_HOST,
    "Emulator environment detected; refusing production seeding.");
  const configuredProject = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || PROJECT_ID;
  assert(configuredProject === PROJECT_ID, `Expected project ${PROJECT_ID}; got ${configuredProject}.`);
  assert(getApps().length === 0, "Unexpected Firebase Admin app already initialized.");
  const app = initializeApp({credential: applicationDefault(), projectId: PROJECT_ID});
  const auth = getAuth(app);
  const db = getFirestore(app);
  // Force ADC validation before any writes.
  await auth.listUsers(1);
  if (apply) assert(process.argv.includes("--apply"), "Missing explicit --apply flag.");
  return {auth, db};
}

async function preflight(auth, db, manifest) {
  const accounts = [
    ...[1, 2].map((n) => ({uid: uid("caregiver", n), email: email("caregiver", n), role: "caregiver", name: caregiverName(n), n})),
    ...manifest.map((c) => ({uid: uid("patient", c.n), email: email("patient", c.n), role: "patient", name: patientName(c.n), n: c.n})),
  ];
  const paths = [];
  for (const account of accounts) paths.push(`users/${account.uid}`);
  for (const c of manifest) {
    const patientId = uid("patient", c.n);
    const caregiverId = uid("caregiver", c.caregiver);
    paths.push(`patientCodes/${patientCode(c.n)}`, `pairings/${caregiverId}_${patientId}`, `treatments/${patientId}`);
    for (const key of ["initial", "month2", "pre_final", "final"]) paths.push(`btaExaminations/bta_${patientId}_${key}`);
    if (c.confirmation) paths.push(`btaExaminations/bta_${patientId}_confirmation`);
    for (let i = 0; i < 7; i++) paths.push(`medicines/demo_${patientId}_${String(i + 1).padStart(2, "0")}`);
    for (let i = 0; i < 7; i++) paths.push(`medicationLogs/demo_${patientId}_${String(i + 1).padStart(2, "0")}`);
    paths.push(`notifications/demo_notification_${String(c.n).padStart(2, "0")}`);
  }
  const [existingByEmail, snapshots] = await Promise.all([
    Promise.all(accounts.map(async (a) => {
      try { return await auth.getUserByEmail(a.email); }
      catch (e) { if (e.code === "auth/user-not-found") return null; throw e; }
    })),
    Promise.all(paths.map((p) => db.doc(p).get())),
  ]);
  const conflicts = [];
  existingByEmail.forEach((u, i) => {
    if (u && (u.uid !== accounts[i].uid || u.email !== accounts[i].email || u.customClaims?.isDemo !== true)) {
      conflicts.push(`Auth email ${accounts[i].email} belongs to a non-seeder account`);
    }
  });
  snapshots.forEach((s, i) => { if (s.exists) conflicts.push(s.ref.path); });
  for (const account of accounts) {
    try {
      const found = await auth.getUser(account.uid);
      if (found.email !== account.email || found.customClaims?.isDemo !== true) {
        conflicts.push(`Auth UID ${account.uid} belongs to a non-seeder account`);
      }
    } catch (e) { if (e.code !== "auth/user-not-found") throw e; }
  }
  assert(conflicts.length === 0,
    `Conflict found; no writes performed. Resolve or choose new demo IDs. First conflicts: ${conflicts.slice(0, 20).join(", ")}`);
  return {accounts, paths: paths.length};
}

async function applySeed(auth, db, manifest, accounts) {
  let saved = null;
  if (fs.existsSync(LOCAL_CREDENTIALS)) {
    saved = JSON.parse(fs.readFileSync(LOCAL_CREDENTIALS, "utf8"));
    assert(saved.projectId === PROJECT_ID && Array.isArray(saved.accounts),
      "Local credential file does not match this production seed.");
  }
  const priorPasswords = Object.fromEntries((saved?.accounts || []).map((a) => [a.email, a.password]));
  const passwords = Object.fromEntries(accounts.map((a) => [a.email, priorPasswords[a.email] || syntheticPassword()]));
  if (!saved) {
    // Persist generated logins locally before the first remote mutation.
    fs.writeFileSync(LOCAL_CREDENTIALS, JSON.stringify({projectId: PROJECT_ID, createdAt: new Date().toISOString(), accounts: accounts.map((a) => ({email: a.email, role: a.role, password: passwords[a.email]}))}, null, 2), {flag: "wx", mode: 0o600});
  }

  for (const account of accounts) {
    let user;
    try {
      user = await auth.getUser(account.uid);
      assert(user.email === account.email && user.customClaims?.isDemo === true,
        `Existing Auth identity ${account.uid} is not a completed demo account.`);
    } catch (e) {
      if (e.code !== "auth/user-not-found") throw e;
      user = await auth.createUser({uid: account.uid, email: account.email, password: passwords[account.email], displayName: account.name, emailVerified: true, disabled: false});
      await auth.setCustomUserClaims(user.uid, {isDemo: true});
    }
  }

  const createdAt = FieldValue.serverTimestamp();
  const ops = [];
  for (const account of accounts) {
    const profile = {
      fullName: account.name, email: account.email,
      phoneNumber: `08000000${String(account.n).padStart(4, "0")}`,
      role: account.role, isDemo: true, notificationsEnabled: true, createdAt,
    };
    if (account.role === "patient") {
      const c = manifest.find((x) => x.n === account.n);
      Object.assign(profile, {patientCode: patientCode(c.n), age: 24 + c.n, ageCategory: "Dewasa", gender: c.n % 2 ? "female" : "male", treatmentGroup: "group1", treatmentStartedAt: ts(c.start), medicationHour: 8, medicationMinute: 0});
    }
    ops.push({ref: db.collection("users").doc(account.uid), data: profile});
  }
  for (const c of manifest) {
    const pid = uid("patient", c.n);
    const cid = uid("caregiver", c.caregiver);
    const pName = patientName(c.n);
    ops.push({ref: db.collection("patientCodes").doc(patientCode(c.n)), data: {patientId: pid, patientName: pName, createdAt}});
    ops.push({ref: db.collection("pairings").doc(`${cid}_${pid}`), data: {caregiverId: cid, patientId: pid, patientName: pName, invitationCode: patientCode(c.n), createdAt}});
    const failureType = c.failure ? "persistent_bacteriological_failure" : "none";
    const treatmentData = {
      patientId: pid, treatmentStartDate: ts(c.start), expectedCompletionDate: ts(c.completion),
      actualCompletionDate: c.status === "completed" ? ts(c.completion) : null,
      status: c.status, confirmedFailureType: failureType,
      failureNotes: c.failure ? "Kegagalan terkonfirmasi untuk skenario demonstrasi." : "",
      ...c.treatment, treatmentOutcome: c.outcome, classificationReason: c.treatment.path.join("\n"), reasoningPath: c.treatment.path,
      lastClassificationUpdate: createdAt, createdAt, updatedAt: createdAt,
    };
    delete treatmentData.path;
    ops.push({ref: db.collection("treatments").doc(pid), data: treatmentData});

    const scheduledMonths = [0, 2, 4, 5];
    for (let i = 0; i < 4; i++) {
      const examId = `bta_${pid}_${["initial", "month2", "pre_final", "final"][i]}`;
      const examDate = addMonths(c.start, scheduledMonths[i]);
      const result = c.results[i];
      ops.push({ref: db.collection("btaExaminations").doc(examId), data: {
        patientId: pid, examinationType: btaTypes[i], scheduledDate: ts(examDate),
        examinationDate: result ? ts(atHour(examDate, 10)) : null, result,
        notes: result ? "Hasil pemeriksaan data demonstrasi." : "",
        enteredByCaregiver: result ? cid : null, systemGenerated: true, createdAt, updatedAt: createdAt,
      }});
    }
    if (c.confirmation) {
      const examDate = addMonths(c.start, 5);
      ops.push({ref: db.collection("btaExaminations").doc(`bta_${pid}_confirmation`), data: {
        patientId: pid, examinationType: "confirmation", scheduledDate: ts(examDate),
        examinationDate: ts(atHour(examDate, 12)), result: c.confirmation,
        notes: "Pemeriksaan konfirmasi data demonstrasi.", enteredByCaregiver: cid,
        systemGenerated: false, createdAt, updatedAt: createdAt,
      }});
    }

    // Seven compact, explicitly synthetic dose examples per patient.
    for (let i = 0; i < 7; i++) {
      const scheduled = atHour(new Date(c.now.getTime() - (6 - i) * 86400000));
      const status = c.n === 3 && i % 3 === 0 ? "missed" : c.n === 7 && i % 2 === 0 ? "missed" : c.n === 8 && i === 6 ? "pending" : c.n === 8 && i === 5 ? "late" : "taken";
      const id = `demo_${pid}_${String(i + 1).padStart(2, "0")}`;
      const responded = status === "pending" ? null : ts(new Date(scheduled.getTime() + (status === "late" ? 3600000 : status === "missed" ? 19 * 3600000 : 5 * 60000)));
      const medicine = {
        caregiverId: cid, patientId: pid, name: "MINUM OBAT", dosage: "Sesuai resep",
        scheduledAt: ts(scheduled), treatmentGroup: "group1", treatmentDay: dayKey(scheduled),
        systemGenerated: false, status, scheduleRevision: 1,
        alarmState: status === "pending" ? "scheduled" : "stopped",
        responseAction: status === "pending" ? null : status === "missed" ? "automatic_missed" : "taken",
        reminderTriggeredAt: null, deviceTriggeredAt: null, deviceTriggerPushedAt: null,
        dueNotifiedAt: null, lateNotifiedAt: null, snoozedUntil: null, dismissedAt: null,
        createdAt, updatedAt: createdAt,
        takenAt: status === "taken" || status === "late" ? responded : null,
        missedAt: status === "missed" ? responded : null, respondedAt: responded,
      };
      ops.push({ref: db.collection("medicines").doc(id), data: medicine});
      if (status !== "pending") ops.push({ref: db.collection("medicationLogs").doc(id), data: {
        medicineId: id, patientId: pid, name: medicine.name, dosage: medicine.dosage,
        scheduledAt: ts(scheduled), status, responseAction: medicine.responseAction,
        takenAt: medicine.takenAt, missedAt: medicine.missedAt,
        respondedAt: responded, recordedAt: responded, scheduleRevision: 1,
      }});
    }
    const notificationId = `demo_notification_${String(c.n).padStart(2, "0")}`;
    ops.push({ref: db.collection("notifications").doc(notificationId), data: {
      recipientId: cid, patientId: pid, medicineId: `demo_${pid}_01`,
      type: c.n === 3 || c.n === 7 ? "missed" : "taken",
      title: c.n === 3 || c.n === 7 ? "Obat terlewat" : "Pembaruan minum obat",
      message: c.n === 3 || c.n === 7 ? `${pName} melewatkan jadwal obat (data demo).` : `${pName} mengonfirmasi jadwal obat (data demo).`,
      read: false, createdAt,
    }});
  }

  assert(ops.length <= 500, `Unexpectedly large batch: ${ops.length} documents.`);
  const batch = db.batch();
  for (const op of ops) batch.create(op.ref, op.data);
  await batch.commit();
  return {documentsCreated: ops.length, credentialFile: LOCAL_CREDENTIALS};
}

async function main() {
  const {apply} = parseArgs();
  const manifest = buildManifest();
  const {auth, db} = await assertDestination(apply);
  const checked = await preflight(auth, db, manifest);
  const summary = {projectId: PROJECT_ID, mode: apply ? "APPLY" : "DRY RUN", accounts: checked.accounts.length, patientCases: manifest.length, dataPathsChecked: checked.paths, planned: {profiles: 10, patientCodes: 8, pairings: 8, treatments: 8, btaExaminations: 33, medicationSchedules: 56, notifications: 8}, conflicts: 0};
  if (!apply) {
    console.log(JSON.stringify({...summary, result: "No writes performed. Repeat with --apply only after reviewing this summary."}, null, 2));
    return;
  }
  const result = await applySeed(auth, db, manifest, checked.accounts);
  console.log(JSON.stringify({...summary, ...result, result: "Created"}, null, 2));
}

main().catch((error) => {
  console.error(`Production demo seeder stopped: ${error.message}`);
  process.exitCode = 1;
});
