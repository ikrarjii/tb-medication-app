const {createHash, randomUUID} = require("node:crypto");
const {initializeApp} = require("firebase-admin/app");
const {
  getFirestore,
  FieldValue,
  Timestamp,
} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentUpdated,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");

initializeApp();
const db = getFirestore();

const DEADLINE_PAGE_SIZE = 200;
const MINUTE_IN_MILLISECONDS = 60 * 1000;
const LATE_AFTER_MINUTES = 10;
const MISSED_AFTER_MINUTES = 18 * 60;
const OUTBOX_RETRY_PAGE_SIZE = 100;
const OUTBOX_LEASE_MILLISECONDS = 5 * MINUTE_IN_MILLISECONDS;
const OUTBOX_MAX_BACKOFF_MILLISECONDS = 60 * MINUTE_IN_MILLISECONDS;
const PERMANENT_MESSAGING_ERRORS = new Set([
  "messaging/invalid-registration-token",
  "messaging/mismatched-credential",
  "messaging/registration-token-not-registered",
  "messaging/sender-id-mismatch",
]);

async function tokensFor(userIds) {
  const uniqueIds = [...new Set(userIds.filter(Boolean))];
  const snapshots = await Promise.all(
    uniqueIds.map((id) => db.collection("users").doc(id).get()),
  );
  return snapshots.flatMap((snapshot) => {
    if (snapshot.data()?.notificationsEnabled === false) return [];
    const tokens = snapshot.data()?.fcmTokens;
    return Array.isArray(tokens) ? tokens : [];
  });
}

async function sendPush(userIds, title, body, data, notificationKey) {
  const tokens = [...new Set(await tokensFor(userIds))];
  const stringData = Object.fromEntries(
    Object.entries(data || {}).map(([key, value]) => [key, String(value)]),
  );
  let successCount = 0;
  let permanentFailureCount = 0;
  const retryableErrors = [];

  for (let offset = 0; offset < tokens.length; offset += 500) {
    const response = await getMessaging().sendEachForMulticast({
      tokens: tokens.slice(offset, offset + 500),
      notification: {title, body},
      data: stringData,
      android: {
        priority: "high",
        collapseKey: notificationKey,
        notification: {
          channelId: "medication_schedule",
          tag: notificationKey,
        },
      },
    });
    successCount += response.successCount;
    for (const result of response.responses) {
      if (result.success) continue;
      const code = result.error?.code || "messaging/unknown-error";
      if (PERMANENT_MESSAGING_ERRORS.has(code)) {
        permanentFailureCount += 1;
      } else {
        retryableErrors.push(code);
      }
    }
  }

  if (retryableErrors.length > 0) {
    throw new Error(
      `Retryable FCM failures: ${[...new Set(retryableErrors)].join(", ")}`,
    );
  }
  return {permanentFailureCount, successCount, tokenCount: tokens.length};
}

async function caregiverIdsFor(patientId) {
  const pairings = await db
    .collection("pairings")
    .where("patientId", "==", patientId)
    .get();
  return pairings.docs
    .map((document) => document.data().caregiverId)
    .filter(Boolean);
}

function revisionOf(medicine) {
  return Number.isInteger(medicine.scheduleRevision) ?
    medicine.scheduleRevision : 1;
}

function medicineEventId(medicineId, eventKey, medicine) {
  return `${medicineId}_${eventKey}_r${revisionOf(medicine)}`;
}

function notificationKeyFor(outboxId) {
  const digest = createHash("sha256").update(outboxId).digest("hex");
  return `medicine_${digest.slice(0, 24)}`;
}

function pendingOutboxData({
  body,
  data,
  eventKey,
  outboxId,
  recipientIds,
  title,
}) {
  return {
    attemptCount: 0,
    body,
    createdAt: FieldValue.serverTimestamp(),
    data: data || {},
    eventKey,
    leaseOwner: null,
    leaseUntil: null,
    nextAttemptAt: FieldValue.serverTimestamp(),
    notificationKey: notificationKeyFor(outboxId),
    recipientIds: [...new Set(recipientIds.filter(Boolean))],
    status: "pending",
    title,
    updatedAt: FieldValue.serverTimestamp(),
  };
}

function outboxCreation(outboxId, payload) {
  return {
    data: pendingOutboxData({...payload, outboxId}),
    reference: db.collection("pushOutbox").doc(outboxId),
  };
}

function caregiverEventCreations({
  caregiverIds,
  eventKey,
  medicineId,
  message,
  patientId,
  title,
  type,
}) {
  const uniqueCaregiverIds = [...new Set(caregiverIds.filter(Boolean))];
  return uniqueCaregiverIds.flatMap((caregiverId) => {
    const notificationId = `${eventKey}_${caregiverId}`;
    const outboxId = `caregiver_${notificationId}`;
    return [
      {
        reference: db.collection("notifications").doc(notificationId),
        data: {
          recipientId: caregiverId,
          patientId,
          medicineId,
          type,
          title,
          message,
          read: false,
          createdAt: FieldValue.serverTimestamp(),
        },
      },
      outboxCreation(outboxId, {
        recipientIds: [caregiverId],
        eventKey,
        title,
        body: message,
        data: {patientId, medicineId, type},
      }),
    ];
  });
}

async function createMissingDocuments(transaction, creations) {
  const uniqueCreations = [...new Map(
    creations.map((creation) => [creation.reference.path, creation]),
  ).values()];
  if (uniqueCreations.length === 0) return;
  const snapshots = await Promise.all(
    uniqueCreations.map(({reference}) => transaction.get(reference)),
  );
  snapshots.forEach((snapshot, index) => {
    if (!snapshot.exists) {
      const creation = uniqueCreations[index];
      transaction.set(creation.reference, creation.data);
    }
  });
}

async function enqueuePushOnce(outboxId, payload) {
  const creation = outboxCreation(outboxId, payload);
  await db.runTransaction(async (transaction) => {
    await createMissingDocuments(transaction, [creation]);
  });
}

function timestampIsDue(value, now) {
  return !(value instanceof Timestamp) || value.toMillis() <= now.toMillis();
}

async function claimPushOutbox(reference) {
  const leaseOwner = randomUUID();
  const now = Timestamp.now();
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(reference);
    if (!snapshot.exists) return null;
    const outbox = snapshot.data();
    const pending = outbox.status === "pending" &&
      timestampIsDue(outbox.nextAttemptAt, now);
    const expired = outbox.status === "processing" &&
      timestampIsDue(outbox.leaseUntil, now);
    if (!pending && !expired) return null;

    const attemptCount = Number.isInteger(outbox.attemptCount) ?
      outbox.attemptCount + 1 : 1;
    transaction.update(reference, {
      attemptCount,
      lastAttemptAt: FieldValue.serverTimestamp(),
      leaseOwner,
      leaseUntil: Timestamp.fromMillis(
        now.toMillis() + OUTBOX_LEASE_MILLISECONDS,
      ),
      status: "processing",
      updatedAt: FieldValue.serverTimestamp(),
    });
    return {...outbox, attemptCount, leaseOwner};
  });
}

async function markPushOutboxSent(reference, claim, result) {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(reference);
    if (!snapshot.exists) return;
    const outbox = snapshot.data();
    if (outbox.status !== "processing" ||
        outbox.leaseOwner !== claim.leaseOwner) {
      return;
    }
    transaction.update(reference, {
      deliveryResult: result,
      lastError: FieldValue.delete(),
      leaseOwner: null,
      leaseUntil: null,
      nextAttemptAt: null,
      sentAt: FieldValue.serverTimestamp(),
      status: "sent",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

function retryDelayMilliseconds(attemptCount) {
  const exponent = Math.max(0, Math.min(attemptCount - 1, 6));
  return Math.min(
    MINUTE_IN_MILLISECONDS * (2 ** exponent),
    OUTBOX_MAX_BACKOFF_MILLISECONDS,
  );
}

async function releasePushOutbox(reference, claim, error) {
  const now = Timestamp.now();
  const message = String(error?.message || error).slice(0, 1000);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(reference);
    if (!snapshot.exists) return;
    const outbox = snapshot.data();
    if (outbox.status !== "processing" ||
        outbox.leaseOwner !== claim.leaseOwner) {
      return;
    }
    transaction.update(reference, {
      lastError: message,
      lastFailedAt: FieldValue.serverTimestamp(),
      leaseOwner: null,
      leaseUntil: null,
      nextAttemptAt: Timestamp.fromMillis(
        now.toMillis() + retryDelayMilliseconds(claim.attemptCount),
      ),
      status: "pending",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

async function processPushOutbox(reference) {
  const claim = await claimPushOutbox(reference);
  if (!claim) return;
  try {
    const result = await sendPush(
      Array.isArray(claim.recipientIds) ? claim.recipientIds : [],
      claim.title || "Kontrol Obat",
      claim.body || "Ada pembaruan pengobatan.",
      claim.data || {},
      claim.notificationKey || notificationKeyFor(reference.id),
    );
    await markPushOutboxSent(reference, claim, result);
  } catch (error) {
    console.error(`Push outbox ${reference.id} failed`, error);
    try {
      await releasePushOutbox(reference, claim, error);
    } catch (releaseError) {
      // An unreleased lease is still recoverable by the expired-lease worker.
      console.error(`Push outbox ${reference.id} release failed`, releaseError);
    }
  }
}

async function retryPushOutboxStatus(status, timeField, now) {
  const snapshot = await db.collection("pushOutbox")
    .where("status", "==", status)
    .where(timeField, "<=", now)
    .orderBy(timeField)
    .limit(OUTBOX_RETRY_PAGE_SIZE)
    .get();
  await Promise.all(snapshot.docs.map((document) =>
    processPushOutbox(document.ref)));
}

exports.onPushOutboxCreated = onDocumentCreated(
  {document: "pushOutbox/{outboxId}", retry: true},
  async (event) => {
    await processPushOutbox(event.data.ref);
  },
);

exports.retryPushOutbox = onSchedule("* * * * *", async () => {
  const now = Timestamp.now();
  await Promise.all([
    retryPushOutboxStatus("pending", "nextAttemptAt", now),
    retryPushOutboxStatus("processing", "leaseUntil", now),
  ]);
});

function displayMedicineName(rawName) {
  const value = typeof rawName === "string" ? rawName.trim() : "";
  if (!value) return "OBAT";
  if (value.toLowerCase() === "obat terapi") return "MINUM OBAT";
  return value.toUpperCase();
}

function deadlineContent(eventKey, patientName, medicineName) {
  const displayName = displayMedicineName(medicineName);
  switch (eventKey) {
    case "due":
      return {
        type: "due",
        title: "Waktu minum obat",
        message: `${patientName} mencapai jadwal ${displayName}.`,
      };
    case "overdue":
      return {
        type: "late",
        title: "Konfirmasi obat terlambat",
        message: `${patientName} belum mengonfirmasi ${displayName} ` +
          `dalam ${LATE_AFTER_MINUTES} menit setelah jadwal.`,
      };
    case "missed":
      return {
        type: "missed",
        title: "Obat terlewat",
        message: `${patientName} melewatkan ${displayName}.`,
      };
    default:
      throw new Error(`Unsupported deadline event: ${eventKey}`);
  }
}

function timestampsEqual(first, second) {
  if (first === second) return true;
  if (!(first instanceof Timestamp) || !(second instanceof Timestamp)) {
    return false;
  }
  return first.isEqual(second);
}

function scheduleFieldsChanged(before, after) {
  return before.name !== after.name ||
    before.dosage !== after.dosage ||
    !timestampsEqual(before.scheduledAt, after.scheduledAt);
}

async function enqueueScheduleChange(action, medicineId, medicine) {
  const patientId = medicine.patientId;
  if (!patientId) return;

  const medicineName = displayMedicineName(medicine.name);
  const labels = {
    created: [
      "Jadwal obat ditambahkan",
      `Jadwal ${medicineName} telah ditambahkan oleh pendamping.`,
    ],
    updated: [
      "Jadwal obat diperbarui",
      `Jadwal ${medicineName} telah diperbarui oleh pendamping.`,
    ],
    deleted: [
      "Jadwal obat dihapus",
      `Jadwal ${medicineName} telah dihapus oleh pendamping.`,
    ],
  };
  const [title, body] = labels[action];
  const eventKey = `schedule_${action}`;
  const eventId = medicineEventId(medicineId, eventKey, medicine);
  await enqueuePushOnce(`patient_${eventId}`, {
    recipientIds: [patientId],
    eventKey,
    title,
    body,
    data: {
      patientId,
      medicineId,
      medicineName,
      dosage: medicine.dosage || "",
      scheduleRevision: revisionOf(medicine),
      scheduledAt: medicine.scheduledAt instanceof Timestamp ?
        medicine.scheduledAt.toMillis() : "",
      type: eventKey,
    },
  });
}

exports.onMedicationStatusChanged = onDocumentUpdated(
  {document: "medicines/{medicineId}", retry: true},
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (before.status === after.status ||
        !["taken", "late", "missed"].includes(after.status)) return;

    // The deadline scheduler writes its automatic missed event atomically.
    // A manual "missed" response carries responseAction and still needs push.
    if (after.status === "missed" && after.responseAction !== "missed") {
      return;
    }

    if (after.responseAction === "taken" &&
        ["taken", "late"].includes(after.status) &&
        after.scheduledAt instanceof Timestamp &&
        after.takenAt instanceof Timestamp) {
      const lateBoundary = after.scheduledAt.toMillis() +
        LATE_AFTER_MINUTES * MINUTE_IN_MILLISECONDS;
      const normalizedStatus = after.takenAt.toMillis() > lateBoundary ?
        "late" : "taken";
      if (after.status !== normalizedStatus) {
        const batch = db.batch();
        batch.update(event.data.after.ref, {
          status: normalizedStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
        batch.update(
          db.collection("medicationLogs").doc(event.params.medicineId),
          {status: normalizedStatus},
        );
        await batch.commit();
        return;
      }
    }

    const caregiverIds = await caregiverIdsFor(after.patientId);
    if (caregiverIds.length === 0) return;
    const patient = await db.collection("users").doc(after.patientId).get();
    const patientName = patient.data()?.fullName || "Pasien";
    const medicineName = displayMedicineName(after.name);
    const labels = {
      taken: [
        "Obat sudah diminum",
        `${patientName} telah minum ${medicineName}.`,
      ],
      late: [
        "Obat diminum terlambat",
        `${patientName} terlambat minum ${medicineName}.`,
      ],
      missed: [
        "Obat terlewat",
        `${patientName} melewatkan ${medicineName}.`,
      ],
    };
    const [title, message] = labels[after.status];
    const eventKey = after.status === "late" ? "taken_late" : after.status;
    const durableEventId = medicineEventId(
      event.params.medicineId,
      eventKey,
      after,
    );
    await db.runTransaction(async (transaction) => {
      const current = await transaction.get(event.data.after.ref);
      if (!current.exists) return;
      const medicine = current.data();
      if (medicine.patientId !== after.patientId ||
          medicine.status !== after.status ||
          revisionOf(medicine) !== revisionOf(after)) {
        return;
      }
      await createMissingDocuments(
        transaction,
        caregiverEventCreations({
          caregiverIds,
          eventKey: durableEventId,
          medicineId: event.params.medicineId,
          message,
          patientId: after.patientId,
          title,
          type: eventKey,
        }),
      );
    });
  },
);

exports.onDeviceReminderTriggered = onDocumentUpdated(
  {document: "medicines/{medicineId}", retry: true},
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (before.deviceTriggeredAt || !after.deviceTriggeredAt) return;

    const caregiverIds = await caregiverIdsFor(after.patientId);
    if (caregiverIds.length === 0) return;
    const patient = await db.collection("users").doc(after.patientId).get();
    const patientName = patient.data()?.fullName || "Pasien";
    const title = "Pengingat obat berbunyi";
    const message = `${patientName} mencapai jadwal ` +
      `${displayMedicineName(after.name)}.`;
    const durableEventId = medicineEventId(
      event.params.medicineId,
      "triggered",
      after,
    );
    await db.runTransaction(async (transaction) => {
      const current = await transaction.get(event.data.after.ref);
      if (!current.exists) return;
      const currentData = current.data();
      const sameTrigger = currentData.deviceTriggeredAt instanceof Timestamp &&
        after.deviceTriggeredAt instanceof Timestamp &&
        currentData.deviceTriggeredAt.isEqual(after.deviceTriggeredAt);
      const sameSchedule = timestampsEqual(
        currentData.scheduledAt,
        after.scheduledAt,
      ) && currentData.scheduleRevision === after.scheduleRevision;
      if (currentData.deviceTriggerPushedAt ||
          currentData.patientId !== after.patientId ||
          !sameTrigger || !sameSchedule) {
        return;
      }
      await createMissingDocuments(
        transaction,
        caregiverEventCreations({
          caregiverIds,
          eventKey: durableEventId,
          medicineId: event.params.medicineId,
          message,
          patientId: after.patientId,
          title,
          type: "triggered",
        }),
      );
      transaction.update(event.data.after.ref, {
        deviceTriggerPushedAt: FieldValue.serverTimestamp(),
      });
    });
  },
);

async function processPendingMedicine(document, deadlineNow) {
  const initialMedicine = document.data();
  if (!initialMedicine.patientId) return;

  const [patient, caregiverIds] = await Promise.all([
    db.collection("users").doc(initialMedicine.patientId).get(),
    caregiverIdsFor(initialMedicine.patientId),
  ]);
  const patientName = patient.data()?.fullName || "Pasien";

  const result = await db.runTransaction(async (transaction) => {
    const current = await transaction.get(document.ref);
    if (!current.exists) return null;

    const medicine = current.data();
    const scheduledAt = medicine.scheduledAt;
    if (medicine.status !== "pending" ||
        !(scheduledAt instanceof Timestamp) ||
        scheduledAt.toMillis() > deadlineNow.toMillis()) {
      return null;
    }

    const elapsedMinutes =
      (deadlineNow.toMillis() - scheduledAt.toMillis()) /
      MINUTE_IN_MILLISECONDS;
    const missed = elapsedMinutes >= MISSED_AFTER_MINUTES;
    const due = !missed && !medicine.dueNotifiedAt;
    const overdue = !missed &&
      elapsedMinutes >= LATE_AFTER_MINUTES &&
      !medicine.lateNotifiedAt;
    const updates = {};
    const events = [];

    if (due) {
      updates.dueNotifiedAt = FieldValue.serverTimestamp();
      events.push("due");
    }
    if (!medicine.reminderTriggeredAt) {
      updates.reminderTriggeredAt = FieldValue.serverTimestamp();
    }
    if (overdue) {
      updates.lateNotifiedAt = FieldValue.serverTimestamp();
      events.push("overdue");
    }
    if (missed) {
      if (!medicine.dueNotifiedAt) {
        updates.dueNotifiedAt = FieldValue.serverTimestamp();
      }
      if (!medicine.lateNotifiedAt) {
        updates.lateNotifiedAt = FieldValue.serverTimestamp();
      }
      updates.status = "missed";
      updates.missedAt = FieldValue.serverTimestamp();
      updates.respondedAt = FieldValue.serverTimestamp();
      updates.responseAction = "automatic_missed";
      updates.alarmState = "missed";
      updates.snoozedUntil = FieldValue.delete();
      updates.updatedAt = FieldValue.serverTimestamp();
      events.push("missed");
    }

    if (Object.keys(updates).length === 0) return null;
    const creations = [];
    for (const eventKey of events) {
      const content = deadlineContent(
        eventKey,
        patientName,
        displayMedicineName(medicine.name),
      );
      const durableEventId = medicineEventId(
        document.id,
        eventKey,
        medicine,
      );
      creations.push(...caregiverEventCreations({
        caregiverIds,
        eventKey: durableEventId,
        medicineId: document.id,
        message: content.message,
        patientId: medicine.patientId,
        title: content.title,
        type: content.type,
      }));
      if (eventKey === "due") {
        const dosage = medicine.dosage ? ` - ${medicine.dosage}` : "";
        const medicineName = displayMedicineName(medicine.name);
        creations.push(outboxCreation(`patient_${durableEventId}`, {
          recipientIds: [medicine.patientId],
          eventKey: "due",
          title: "Waktunya minum obat",
          body: `${medicineName}${dosage}`,
          data: {
            patientId: medicine.patientId,
            medicineId: document.id,
            medicineName,
            dosage: medicine.dosage || "",
            scheduleRevision: revisionOf(medicine),
            scheduledAt: scheduledAt.toMillis(),
            type: "due",
          },
        }));
      }
    }

    await createMissingDocuments(transaction, creations);
    transaction.update(document.ref, updates);

    if (missed) {
      transaction.set(db.collection("medicationLogs").doc(document.id), {
        medicineId: document.id,
        patientId: medicine.patientId,
        name: medicine.name || "Obat tanpa nama",
        dosage: medicine.dosage || null,
        scheduledAt,
        status: "missed",
        responseAction: "automatic_missed",
        missedAt: FieldValue.serverTimestamp(),
        respondedAt: FieldValue.serverTimestamp(),
        recordedAt: FieldValue.serverTimestamp(),
      });
    }

    return true;
  });
  if (!result) return;
}

exports.checkMedicationDeadlines = onSchedule("* * * * *", async () => {
  const deadlineNow = Timestamp.now();
  let cursor = null;
  let firstError = null;

  while (true) {
    let query = db
      .collection("medicines")
      .where("status", "==", "pending")
      .where("scheduledAt", "<=", deadlineNow)
      .orderBy("scheduledAt")
      .limit(DEADLINE_PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);

    const page = await query.get();
    if (page.empty) break;
    cursor = page.docs[page.docs.length - 1];

    const results = await Promise.allSettled(
      page.docs.map((document) =>
        processPendingMedicine(document, deadlineNow)),
    );
    for (const result of results) {
      if (result.status === "rejected" && firstError === null) {
        firstError = result.reason;
      }
    }
    if (page.size < DEADLINE_PAGE_SIZE) break;
  }

  if (firstError !== null) throw firstError;
});

exports.onMedicineCreated = onDocumentCreated(
  {document: "medicines/{medicineId}", retry: true},
  async (event) => {
    await enqueueScheduleChange(
      "created",
      event.params.medicineId,
      event.data.data(),
    );
  },
);

exports.onMedicineScheduleUpdated = onDocumentUpdated(
  {document: "medicines/{medicineId}", retry: true},
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (!scheduleFieldsChanged(before, after)) return;
    await enqueueScheduleChange(
      "updated",
      event.params.medicineId,
      after,
    );
  },
);

exports.onMedicineDeleted = onDocumentDeleted(
  {document: "medicines/{medicineId}", retry: true},
  async (event) => {
    await enqueueScheduleChange(
      "deleted",
      event.params.medicineId,
      event.data.data(),
    );
  },
);

exports.onCaregiverReminderCreated = onDocumentCreated(
  {document: "reminders/{reminderId}", retry: true},
  async (event) => {
    const reminder = event.data.data();
    await enqueuePushOnce(`patient_reminder_${event.params.reminderId}`, {
      recipientIds: [reminder.patientId],
      eventKey: "caregiver_reminder",
      title: "Pengingat dari pendamping",
      body: "Pendamping mengingatkan Anda untuk memeriksa jadwal obat.",
      data: {
        caregiverId: reminder.caregiverId || "",
        patientId: reminder.patientId,
        reminderId: event.params.reminderId,
        type: "caregiver_reminder",
      },
    });
  },
);

// ---------------------------------------------------------------------------
// Tuberculosis BTA monitoring and deterministic treatment outcome tree.
// ---------------------------------------------------------------------------

function addMonthsClamped(timestamp, months) {
  const source = timestamp.toDate();
  const targetFirst = new Date(Date.UTC(
    source.getUTCFullYear(),
    source.getUTCMonth() + months,
    1,
    source.getUTCHours(),
    source.getUTCMinutes(),
    source.getUTCSeconds(),
    source.getUTCMilliseconds(),
  ));
  const finalDay = new Date(Date.UTC(
    targetFirst.getUTCFullYear(),
    targetFirst.getUTCMonth() + 1,
    0,
  )).getUTCDate();
  targetFirst.setUTCDate(Math.min(source.getUTCDate(), finalDay));
  return Timestamp.fromDate(targetFirst);
}

async function ensureBtaMonitoring(patientId, patient) {
  if (patient.role !== "patient" ||
      !(patient.treatmentStartedAt instanceof Timestamp)) {
    return;
  }
  const treatmentRef = db.collection("treatments").doc(patientId);
  const start = patient.treatmentStartedAt;
  const completion = addMonthsClamped(start, 6);
  const schedules = [
    ["initial", "initial", start],
    ["month2", "month_2", addMonthsClamped(start, 2)],
    ["pre_final", "pre_final", addMonthsClamped(start, 4)],
    ["final", "final", addMonthsClamped(start, 5)],
  ];
  await db.runTransaction(async (transaction) => {
    const references = schedules.map(([key]) =>
      db.collection("btaExaminations").doc(`bta_${patientId}_${key}`));
    const [treatment, ...examinations] = await Promise.all([
      transaction.get(treatmentRef),
      ...references.map((reference) => transaction.get(reference)),
    ]);
    if (!treatment.exists) {
      transaction.set(treatmentRef, {
        patientId,
        treatmentStartDate: start,
        expectedCompletionDate: completion,
        actualCompletionDate: null,
        status: "ongoing",
        confirmedFailureType: "none",
        failureNotes: "",
        conversionDetected: false,
        possibleReversal: false,
        confirmedReversal: false,
        confirmedFailure: false,
        treatmentOutcome: "TREATMENT IN PROGRESS",
        classificationReason: [
          "Treatment completed? NO",
          "Confirmed treatment failure? NO",
          "Final classification: TREATMENT IN PROGRESS",
        ].join("\n"),
        reasoningPath: [
          "Treatment completed? NO",
          "Confirmed treatment failure? NO",
          "Final classification: TREATMENT IN PROGRESS",
        ],
        lastClassificationUpdate: FieldValue.serverTimestamp(),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    examinations.forEach((snapshot, index) => {
      const [, type, scheduledDate] = schedules[index];
      if (snapshot.exists) {
        const data = snapshot.data();
        const updates = {};
        if (data.examinationType === "month2" && type === "month_2") {
          updates.examinationType = type;
        }
        if (data.systemGenerated === true && data.result == null &&
            (!(data.scheduledDate instanceof Timestamp) ||
              !data.scheduledDate.isEqual(scheduledDate))) {
          updates.scheduledDate = scheduledDate;
        }
        if (Object.keys(updates).length > 0) {
          updates.updatedAt = FieldValue.serverTimestamp();
          transaction.update(references[index], updates);
        }
        return;
      }
      transaction.set(references[index], {
        patientId,
        examinationType: type,
        scheduledDate,
        examinationDate: null,
        result: null,
        notes: "",
        enteredByCaregiver: null,
        systemGenerated: true,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  });
}

exports.onPatientProfileCreatedForBta = onDocumentCreated(
  {document: "users/{userId}", retry: true},
  async (event) => {
    await ensureBtaMonitoring(event.params.userId, event.data.data());
  },
);

exports.onPatientTreatmentStartAddedForBta = onDocumentUpdated(
  {document: "users/{userId}", retry: true},
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    if (timestampsEqual(before.treatmentStartedAt, after.treatmentStartedAt)) {
      return;
    }
    await ensureBtaMonitoring(event.params.userId, after);
  },
);

function btaChronological(first, second) {
  const firstDate = first.examinationDate instanceof Timestamp ?
    first.examinationDate : first.scheduledDate;
  const secondDate = second.examinationDate instanceof Timestamp ?
    second.examinationDate : second.scheduledDate;
  const byDate = firstDate.toMillis() - secondDate.toMillis();
  return byDate === 0 ? String(first.id).localeCompare(String(second.id)) : byDate;
}

function calculateTreatmentDecision(treatment, examinationDocuments) {
  const examinations = examinationDocuments
    .map((document) => ({id: document.id, ...document.data()}))
    .filter((exam) => exam.result != null)
    .sort(btaChronological);
  const valid = examinations.filter((exam) =>
    exam.result === "positive" || exam.result === "negative");
  const initial = examinations.filter((exam) =>
    exam.examinationType === "initial").at(-1);
  const finalExam = examinations.filter((exam) =>
    exam.examinationType === "final").at(-1);

  let positiveSeen = false;
  let conversionIndex = null;
  valid.forEach((exam, index) => {
    if (conversionIndex != null) return;
    if (exam.result === "positive") positiveSeen = true;
    if (positiveSeen && exam.result === "negative") conversionIndex = index;
  });
  const conversionDetected = conversionIndex != null;
  let possibleReversal = false;
  let confirmedReversal = false;
  if (conversionIndex != null) {
    let possiblePositiveSeen = false;
    for (let index = conversionIndex + 1; index < valid.length; index += 1) {
      const exam = valid[index];
      if (possiblePositiveSeen && exam.examinationType === "confirmation") {
        if (exam.result === "positive") {
          possibleReversal = true;
          confirmedReversal = true;
          break;
        }
        possiblePositiveSeen = false;
        possibleReversal = false;
        continue;
      }
      if (exam.result !== "positive") continue;
      if (!possiblePositiveSeen) {
        possiblePositiveSeen = true;
        possibleReversal = true;
      }
    }
  }

  const treatmentCompleted = treatment.status === "completed";
  const initialPositive = initial?.result === "positive";
  const finalNegative = finalExam?.result === "negative";
  const explicitFailure = treatment.confirmedFailureType != null &&
    treatment.confirmedFailureType !== "none";
  const confirmedFailure = explicitFailure || confirmedReversal;
  const path = [
    `Treatment completed? ${treatmentCompleted ? "YES" : "NO"}`,
  ];
  let outcome;

  if (!treatmentCompleted) {
    path.push(`Confirmed treatment failure? ${confirmedFailure ? "YES" : "NO"}`);
    outcome = confirmedFailure ? "FAILED" : "TREATMENT IN PROGRESS";
  } else {
    path.push(`Initial BTA positive? ${initialPositive ? "YES" : "NO"}`);
    if (initialPositive) {
      path.push(`BTA conversion detected? ${conversionDetected ? "YES" : "NO"}`);
      if (conversionDetected) {
        path.push(
          `Confirmed bacteriological reversal? ${confirmedReversal ? "YES" : "NO"}`,
        );
        if (confirmedReversal) {
          outcome = "FAILED";
        } else {
          path.push(`Final BTA negative? ${finalNegative ? "YES" : "NO"}`);
          if (finalNegative) {
            path.push(
              `Confirmed treatment failure? ${confirmedFailure ? "YES" : "NO"}`,
            );
            outcome = confirmedFailure ? "FAILED" : "CURED";
          }
        }
      }
    }
    if (outcome == null) {
      path.push(
        `Confirmed treatment failure? ${confirmedFailure ? "YES" : "NO"}`,
      );
      outcome = confirmedFailure ? "FAILED" : "TREATMENT COMPLETED";
    }
  }
  path.push(`Final classification: ${outcome}`);
  return {
    classificationReason: path.join("\n"),
    confirmedFailure,
    confirmedReversal,
    conversionDetected,
    outcome,
    possibleReversal,
    reasoningPath: path,
  };
}

function safeEventPart(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9]+/g, "_");
}

async function createTreatmentWarningNotifications({
  eventKey,
  message,
  patientId,
  title,
  type,
}) {
  const caregiverIds = await caregiverIdsFor(patientId);
  const creations = caregiverEventCreations({
    caregiverIds,
    eventKey,
    medicineId: `treatment_${patientId}`,
    message,
    patientId,
    title,
    type,
  });
  await db.runTransaction(async (transaction) => {
    await createMissingDocuments(transaction, creations);
  });
}

async function recalculateTreatmentOutcome(patientId, sourceKey) {
  const treatmentRef = db.collection("treatments").doc(patientId);
  const [treatmentSnapshot, examinationSnapshot] = await Promise.all([
    treatmentRef.get(),
    db.collection("btaExaminations")
      .where("patientId", "==", patientId)
      .get(),
  ]);
  if (!treatmentSnapshot.exists) return;
  const before = treatmentSnapshot.data();
  const decision = calculateTreatmentDecision(before, examinationSnapshot.docs);
  const changed = before.treatmentOutcome !== decision.outcome ||
    before.conversionDetected !== decision.conversionDetected ||
    before.possibleReversal !== decision.possibleReversal ||
    before.confirmedReversal !== decision.confirmedReversal ||
    before.confirmedFailure !== decision.confirmedFailure ||
    before.classificationReason !== decision.classificationReason;
  if (!changed) return;

  await treatmentRef.update({
    classificationReason: decision.classificationReason,
    confirmedFailure: decision.confirmedFailure,
    confirmedReversal: decision.confirmedReversal,
    conversionDetected: decision.conversionDetected,
    lastClassificationUpdate: FieldValue.serverTimestamp(),
    possibleReversal: decision.possibleReversal,
    reasoningPath: decision.reasoningPath,
    treatmentOutcome: decision.outcome,
  });

  if (before.treatmentOutcome !== decision.outcome) {
    await createTreatmentWarningNotifications({
      patientId,
      eventKey: `outcome_${safeEventPart(decision.outcome)}_${sourceKey}`,
      title: "Treatment outcome updated",
      message: `Decision Tree outcome changed to ${decision.outcome}.`,
      type: "treatment_outcome_changed",
    });
  }
  if (!before.possibleReversal && decision.possibleReversal &&
      !decision.confirmedReversal) {
    await createTreatmentWarningNotifications({
      patientId,
      eventKey: `possible_reversal_${sourceKey}`,
      title: "Possible bacteriological reversal",
      message: "A positive BTA appeared after conversion. A repeat confirmation examination is required.",
      type: "possible_reversal",
    });
  }
}

exports.onBtaExaminationWritten = onDocumentWritten(
  {document: "btaExaminations/{examinationId}", retry: true},
  async (event) => {
    const data = event.data.after.exists ?
      event.data.after.data() : event.data.before.data();
    const updateMillis = event.data.after.exists ?
      event.data.after.updateTime.toMillis() : event.data.before.updateTime.toMillis();
    await recalculateTreatmentOutcome(
      data.patientId,
      `${event.params.examinationId}_${updateMillis}`,
    );
    const beforeResult = event.data.before.exists ?
      event.data.before.data().result : null;
    if (data.result === "positive" && beforeResult !== "positive" &&
        data.examinationType !== "initial" &&
        data.examinationType !== "confirmation") {
      await createTreatmentWarningNotifications({
        patientId: data.patientId,
        eventKey: `possible_failure_${event.params.examinationId}_${updateMillis}`,
        title: "Possible treatment failure",
        message: "A follow-up BTA result is positive. Medical review and a repeat confirmation examination are required before classifying failure.",
        type: "possible_treatment_failure",
      });
    }
  },
);

exports.onTreatmentInputsUpdated = onDocumentUpdated(
  {document: "treatments/{patientId}", retry: true},
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();
    const inputChanged = before.status !== after.status ||
      !timestampsEqual(before.actualCompletionDate, after.actualCompletionDate) ||
      before.confirmedFailureType !== after.confirmedFailureType ||
      before.failureNotes !== after.failureNotes ||
      !timestampsEqual(before.treatmentStartDate, after.treatmentStartDate) ||
      !timestampsEqual(
        before.expectedCompletionDate,
        after.expectedCompletionDate,
      );
    if (!inputChanged) return;
    await recalculateTreatmentOutcome(
      event.params.patientId,
      `treatment_${event.data.after.updateTime.toMillis()}`,
    );
  },
);

function examinationReminderCreations({
  examinationId,
  patientId,
  recipients,
  eventKey,
  title,
  message,
  type,
}) {
  return recipients.flatMap((recipientId) => {
    const notificationId = `${examinationId}_${eventKey}_${recipientId}`;
    const outboxId = `bta_${notificationId}`;
    return [
      {
        reference: db.collection("notifications").doc(notificationId),
        data: {
          recipientId,
          patientId,
          examinationId,
          type,
          title,
          message,
          read: false,
          createdAt: FieldValue.serverTimestamp(),
        },
      },
      outboxCreation(outboxId, {
        recipientIds: [recipientId],
        eventKey,
        title,
        body: message,
        data: {patientId, examinationId, type},
      }),
    ];
  });
}

exports.checkBtaExaminationReminders = onSchedule(
  {schedule: "0 8 * * *", timeZone: "Asia/Makassar"},
  async () => {
    const now = Timestamp.now();
    const snapshot = await db.collection("btaExaminations")
      .where("result", "==", null)
      .where("scheduledDate", "<=", now)
      .orderBy("scheduledDate")
      .limit(1000)
      .get();
    const creations = [];
    for (const document of snapshot.docs) {
      const examination = document.data();
      if (examination.result != null ||
          !(examination.scheduledDate instanceof Timestamp)) {
        continue;
      }
      const windowEnd = addMonthsClamped(examination.scheduledDate, 1);
      const patient = await db.collection("users").doc(examination.patientId).get();
      const patientName = patient.data()?.fullName || "Patient";
      const labels = {
        initial: "pemeriksaan pertama pada bulan ke-1",
        month_2: "pemeriksaan kedua pada bulan ke-3",
        pre_final: "pemeriksaan ketiga pada bulan ke-5",
        final: "pemeriksaan keempat pada bulan ke-6",
      };
      const windowLabel = labels[examination.examinationType] ||
        "pemeriksaan BTA";

      if (now.toMillis() < windowEnd.toMillis()) {
        creations.push(...examinationReminderCreations({
          examinationId: document.id,
          patientId: examination.patientId,
          recipients: [examination.patientId],
          eventKey: "bta_window_open",
          title: "Rentang pemeriksaan BTA",
          message: `Rentang ${windowLabel} sudah dimulai. Silakan lakukan pemeriksaan dalam bulan terapi ini.`,
          type: "bta_examination_reminder",
        }));
        const caregiverIds = await caregiverIdsFor(examination.patientId);
        creations.push(...examinationReminderCreations({
          examinationId: document.id,
          patientId: examination.patientId,
          recipients: caregiverIds,
          eventKey: "bta_window_open_caregiver",
          title: "Rentang pemeriksaan BTA dimulai",
          message: `Rentang ${windowLabel} untuk ${patientName} sudah dimulai.`,
          type: "bta_examination_approaching",
        }));
      } else {
        const caregiverIds = await caregiverIdsFor(examination.patientId);
        creations.push(...examinationReminderCreations({
          examinationId: document.id,
          patientId: examination.patientId,
          recipients: caregiverIds,
          eventKey: "bta_result_overdue",
          title: "Hasil BTA belum diisi",
          message: `Rentang ${windowLabel} untuk ${patientName} telah berakhir dan hasilnya belum diisi.`,
          type: "bta_result_overdue",
        }));
      }
    }
    for (let offset = 0; offset < creations.length; offset += 200) {
      const page = creations.slice(offset, offset + 200);
      await db.runTransaction(async (transaction) => {
        await createMissingDocuments(transaction, page);
      });
    }
  },
);
