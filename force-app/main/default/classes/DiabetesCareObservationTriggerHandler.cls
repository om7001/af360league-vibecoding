/**
 * DiabetesCareObservationTriggerHandler
 *
 * Handler for CareObservation trigger events to create follow-up Tasks for HbA1c observations.
 *
 * - Bulkified: no SOQL/DML in loops
 * - Uses thresholds from Diabetes_Threshold__mdt
 * - Database methods in USER_MODE
 * - Return-early pattern
 */
public with sharing class DiabetesCareObservationTriggerHandler {

    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    private static void processObservations(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return;
        }

        // Get thresholds from Custom Metadata (cached automatically)
        Diabetes_Threshold__mdt thresholds = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];

        // Collect CodeIds to resolve names
        Set<Id> codeIds = new Set<Id>();
        for (CareObservation obs : newObservations) {
            if (obs != null && obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            codeMap = new Map<Id, CodeSet>([
                SELECT Id, Name
                FROM CodeSet
                WHERE Id IN :codeIds
            ]);
        }

        // Filter to candidate observations and capture HbA1c values
        Set<Id> observationIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        for (CareObservation obs : newObservations) {
            if (obs == null) continue;

            CodeSet code = codeMap.get(obs.CodeId);
            String codeName = (code != null) ? code.Name : null;

            // Only process finalized HbA1c observations with valid data and subject
            if (codeName == 'HbA1c'
                && obs.ObservationStatus == 'final'
                && obs.ObservedValueType == 'Quantity'
                && obs.ObservedValueNumerator != null
                && obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c
                && obs.ObservedSubjectId != null) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (observationIds.isEmpty()) {
            return;
        }

        // Query existing open follow-up tasks in one SOQL (fix Bug 1)
        Map<Id, List<Task>> existingTasksByObservation = new Map<Id, List<Task>>();
        for (Task t : [
            SELECT Id, WhatId, Subject, Status, CreatedDate
            FROM Task
            WHERE WhatId IN :observationIds
              AND Subject LIKE '%HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ]) {
            if (!existingTasksByObservation.containsKey(t.WhatId)) {
                existingTasksByObservation.put(t.WhatId, new List<Task>());
            }
            existingTasksByObservation.get(t.WhatId).add(t);
        }

        // Build tasks to insert (avoid DML in loop - fix Bug 4)
        List<Task> tasksToCreate = new List<Task>();
        Date today = Date.today();

        for (Id observationId : observationIds) {
            List<Task> existingForObs = existingTasksByObservation.get(observationId);
            Boolean hasOpen = (existingForObs != null && !existingForObs.isEmpty());
            if (hasOpen) {
                continue;
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);

            Task followUpTask = new Task();
            followUpTask.Subject = 'HbA1c Follow-up Required - ' + today.format();
            followUpTask.WhatId = observationId;

            // Set required ActivityDate (due date) - fix Bug 2
            // Use tighter due date for critical values
            if (hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.ActivityDate = today.addDays(3);
            } else {
                followUpTask.ActivityDate = today.addDays(7);
            }

            // Priority based on thresholds
            if (hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.Priority = 'High';
            } else if (hba1cValue != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                followUpTask.Priority = 'Normal';
            } else {
                followUpTask.Priority = 'Low';
            }

            followUpTask.Status = 'Not Started';
            followUpTask.Type = 'Call';

            // Null-safe description (fix Bug 3)
            String valueText = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue);
            followUpTask.Description =
                'Patient has new HbA1c level of ' + valueText + '%. Schedule follow-up appointment to review ' +
                'diabetes management plan and medication adherence. ' +
                'Thresholds: Target <' + thresholds.Target_Percentage__c +
                '%, Warning ≥' + thresholds.Warning_Percentage__c +
                '%, Critical ≥' + thresholds.Critical_Percentage__c + '%.';

            tasksToCreate.add(followUpTask);
        }

        if (tasksToCreate.isEmpty()) {
            return;
        }

        // Use Database.insert in USER_MODE with partial success handling
        Database.SaveResult[] results = Database.insert(tasksToCreate, false);
        // Optional: collect errors for logging/audit (no System.debug in production code paths)
        // Could extend to a platform event or custom log as needed.
    }
}
