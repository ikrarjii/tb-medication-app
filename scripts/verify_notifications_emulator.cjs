#!/usr/bin/env node
"use strict";

// Integration check for the local demo project only. Creates uniquely named
// dummy records and never writes to the configured production project.
const {createRequire} = require("node:module");
const path = require("node:path");
const adminRequire = createRequire(path.resolve(__dirname, "..", "functions", "package.json"));
const {getApps} = adminRequire("firebase-admin/app");
const {getAuth} = adminRequire("firebase-admin/auth");
const {getFirestore, FieldValue, Timestamp} = adminRequire("firebase-admin/firestore");
const crypto = require("node:crypto");

const PROJECT_ID = "demo-tb-monitoring";
const FIRESTORE_HOST = "127.0.0.1:8180";
const AUTH_HOST = "127.0.0.1:9199";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function waitFor(label, predicate, timeoutMs = 90000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await predicate();
    if (result) return result;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

async function emulatorToken(email, password) {
  const response = await fetch(
    `http://${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-api-key`,
    {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({email, password, returnSecureToken: true}),
    },
  );
  const result = await response.json();
  assert(response.ok,
    `Auth Emulator sign-in failed: ${JSON.stringify(result)}`);
  return result.idToken;
}

async function runScheduledDeadlineCheck(checkMedicationDeadlines) {
  // The Functions Emulator cannot deliver scheduled v2 functions from its
  // Pub/Sub fake (it reports "Unsupported trigger signature: http"). Invoke
  // the same exported handler directly while its Admin SDK targets demo data.
  assert(typeof checkMedicationDeadlines?.run === "function",
    "Scheduled deadline handler is unavailable for direct emulator testing.");
  await checkMedicationDeadlines.run();
}

async function main() {
  assert(process.env.GCLOUD_PROJECT === PROJECT_ID,
    `Refusing non-demo project ${process.env.GCLOUD_PROJECT || "(unset)"}`);
  assert(process.env.FIRESTORE_EMULATOR_HOST === FIRESTORE_HOST,
    `Expected Firestore Emulator at ${FIRESTORE_HOST}`);
  assert(process.env.FIREBASE_AUTH_EMULATOR_HOST === AUTH_HOST,
    `Expected Auth Emulator at ${AUTH_HOST}`);
  assert(process.env.FIREBASE_CONFIG &&
    JSON.parse(process.env.FIREBASE_CONFIG).projectId === PROJECT_ID,
  "Firebase CLI must set FIREBASE_CONFIG to the demo project.");

  const hubResponse = await fetch("http://127.0.0.1:4400/emulators");
  assert(hubResponse.ok, "Emulator Hub is not reachable.");
  const hub = await hubResponse.json();
  assert(hub.functions?.host === "127.0.0.1" && hub.functions?.port === 5101,
    "Functions Emulator is not registered on the expected endpoint.");
  assert(hub.pubsub?.host === "127.0.0.1" && hub.pubsub?.port === 8285,
    "Pub/Sub Emulator is not running; scheduled notification triggers are disabled.");

  process.env.GCLOUD_PROJECT = PROJECT_ID;
  process.env.GOOGLE_CLOUD_PROJECT = PROJECT_ID;
  const functionHandlers = require("../functions/index.js");
  assert(getApps().length > 0, "Firebase Admin default app did not initialize.");
  const auth = getAuth();
  const db = getFirestore();
  const tag = crypto.randomBytes(5).toString("hex");
  const caregiverId = `audit_cg_${tag}`;
  const patientId = `audit_pt_${tag}`;
  const otherId = `audit_other_${tag}`;
  const caregiverEmail = `${caregiverId}@example.test`;
  const patientEmail = `${patientId}@example.test`;
  const otherEmail = `${otherId}@example.test`;
  const password = `Audit-${crypto.randomBytes(12).toString("hex")}!`;

  for (const [uid, email] of [
    [caregiverId, caregiverEmail], [patientId, patientEmail], [otherId, otherEmail],
  ]) {
    await auth.createUser({uid, email, password, emailVerified: true});
  }
  const now = FieldValue.serverTimestamp();
  await Promise.all([
    db.collection("users").doc(caregiverId).set({
      fullName: "Dummy Pengawas", email: caregiverEmail, role: "caregiver",
      phoneNumber: "08000000001", notificationsEnabled: true, createdAt: now,
    }),
    db.collection("users").doc(patientId).set({
      fullName: "Dummy Pasien", email: patientEmail, role: "patient",
      phoneNumber: "08000000002", notificationsEnabled: true, createdAt: now,
    }),
    db.collection("users").doc(otherId).set({
      fullName: "Dummy Pengawas Lain", email: otherEmail, role: "caregiver",
      phoneNumber: "08000000003", notificationsEnabled: true, createdAt: now,
    }),
    db.collection("pairings").doc(`${caregiverId}_${patientId}`).set({
      caregiverId, patientId, patientName: "Dummy Pasien",
      invitationCode: `AUD${tag.toUpperCase()}`, createdAt: now,
    }),
  ]);

  const medicineRef = db.collection("medicines").doc(`audit_taken_${tag}`);
  await medicineRef.set({
    caregiverId, patientId, name: "Obat Audit", dosage: "1 tablet",
    scheduledAt: Timestamp.fromMillis(Date.now() + 3600000),
    status: "pending", createdAt: now, updatedAt: now,
    responseAction: null, scheduleRevision: 1,
  });
  const scheduleCreatedPush = `patient_${medicineRef.id}_schedule_created_r1`;
  await waitFor("schedule-create trigger", async () =>
    (await db.collection("pushOutbox").doc(scheduleCreatedPush).get()).exists);
  await medicineRef.update({
    scheduledAt: Timestamp.fromMillis(Date.now() + 7200000),
    scheduleRevision: 2, updatedAt: FieldValue.serverTimestamp(),
  });
  const scheduleUpdatedPush = `patient_${medicineRef.id}_schedule_updated_r2`;
  await waitFor("schedule-update trigger", async () =>
    (await db.collection("pushOutbox").doc(scheduleUpdatedPush).get()).exists);

  await medicineRef.update({
    status: "taken", responseAction: "taken", takenAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  const takenId = `${medicineRef.id}_taken_r2_${caregiverId}`;
  const takenDoc = await waitFor("taken notification", async () => {
    const snapshot = await db.collection("notifications").doc(takenId).get();
    return snapshot.exists ? snapshot : null;
  });
  assert(takenDoc.data().recipientId === caregiverId,
    "Taken notification recipient is not the linked caregiver UID.");
  assert(takenDoc.data().patientId === patientId,
    "Taken notification patient UID is incorrect.");

  const missedRef = db.collection("medicines").doc(`audit_missed_${tag}`);
  await missedRef.set({
    caregiverId, patientId, name: "Obat Audit Terlewat", dosage: "1 tablet",
    scheduledAt: Timestamp.fromMillis(Date.now() - 19 * 60 * 60 * 1000),
    status: "pending", createdAt: now, updatedAt: now,
    dueNotifiedAt: null, lateNotifiedAt: null, responseAction: null,
    scheduleRevision: 1,
  });
  await runScheduledDeadlineCheck(functionHandlers.checkMedicationDeadlines);
  const missedId = `${missedRef.id}_missed_r1_${caregiverId}`;
  const missedDoc = await waitFor("automatic overdue/missed notifications", async () => {
    const snapshot = await db.collection("notifications").doc(missedId).get();
    return snapshot.exists ? snapshot : null;
  }, 150000);
  assert(missedDoc.data().recipientId === caregiverId,
    "Missed-dose notification recipient is not the linked caregiver UID.");

  const caregiverToken = await emulatorToken(caregiverEmail, password);
  const otherToken = await emulatorToken(otherEmail, password);
  const notificationPath = `http://${FIRESTORE_HOST}/v1/projects/${PROJECT_ID}/databases/(default)/documents/notifications/${takenId}`;
  const ownerRead = await fetch(notificationPath, {
    headers: {authorization: `Bearer ${caregiverToken}`},
  });
  assert(ownerRead.status === 200,
    `Caregiver cannot read its notification (HTTP ${ownerRead.status}).`);
  const otherRead = await fetch(notificationPath, {
    headers: {authorization: `Bearer ${otherToken}`},
  });
  assert(otherRead.status === 403,
    `Another account read the notification (HTTP ${otherRead.status}).`);

  console.log(JSON.stringify({
    projectId: PROJECT_ID,
    emulatorEndpoints: {auth: AUTH_HOST, firestore: FIRESTORE_HOST, functions: "127.0.0.1:5101"},
    scheduleCreatedTrigger: "pass (patient push outbox created)",
    scheduleUpdatedTrigger: "pass (patient push outbox created)",
    takenStatusNotification: "pass",
    automaticMissedDoseNotification: "pass",
    correctCaregiverRecipient: "pass",
    recipientCanRead: "pass",
    otherAccountDenied: "pass",
    sampleIds: {caregiverId, patientId, notificationId: takenId},
  }, null, 2));
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
