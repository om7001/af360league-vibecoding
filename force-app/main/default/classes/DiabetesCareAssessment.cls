/**
 * DiabetesCareAssessment
 * Apex class to assess diabetes care for patients based on latest HbA1c observations
 * and active enrollment in Diabetes care programs.
 *
 * This class is invocable from Flow/Process Builder and other automation tools.
 *
 * Design:
 * - Bulkified processing of multiple patients
 * - Early-return pattern for invalid inputs and system-level issues
 * - Queries and Database operations executed in USER_MODE where applicable
 * - Uses enums for risk categories rather than string literals
 *
 * Security:
 * - with sharing to honor org sharing
 * - Queries executed WITH USER_MODE to respect FLS and sharing
 *
 * @author Agentforce
 * @group Health Cloud
 * @date 2025-12-21
 */
public with sharing class DiabetesCareAssessment {

    /**
     * Risk categorization based on HbA1c thresholds.
     * Enum naming follows ALL_CAPS_SNAKE_CASE as per project rules.
     */
    public enum RISK_CATEGORY {
        WELL_CONTROLLED,
        NEEDS_ATTENTION,
        HIGH_RISK_URGENT,
        NO_DATA_AVAILABLE
    }

    /**
     * Converts enum to user-facing label required by prompt.
     */
    private static String riskCategoryToString(RISK_CATEGORY rc) {
        switch on rc {
            when WELL_CONTROLLED     { return 'Well Controlled'; }
            when NEEDS_ATTENTION     { return 'Needs Attention'; }
            when HIGH_RISK_URGENT    { return 'High Risk/Urgent'; }
            when NO_DATA_AVAILABLE   { return 'No Data Available'; }
        }
        // Return-early fallback
        return 'No Data Available';
    }

    /**
     * Input wrapper for invocable method.
     */
    public class AssessmentRequest {
        @InvocableVariable(required=true label='Patient Id' description='The Salesforce Id of the patient (Account) to assess')
        public Id patientId;

        @InvocableVariable(label='Days Lookback' description='Number of days to look back for observations (currently unused)')
        public Integer daysLookback;

        public AssessmentRequest() {}
        public AssessmentRequest(Id patientId, Integer daysLookback) {
            this.patientId = patientId;
            this.daysLookback = daysLookback;
        }
    }

    /**
     * Output wrapper for invocable method.
     */
    public class AssessmentResult {
        @InvocableVariable(label='Patient Id' description='The Salesforce Id of the patient that was assessed')
        public Id patientId;

        @InvocableVariable(label='HbA1c Value' description='The latest HbA1c numeric value found for the patient (null if not found)')
        public Decimal hba1cValue;

        @InvocableVariable(label='Risk Category' description='Risk category based on HbA1c value and threshold rules')
        public String riskCategory;

        @InvocableVariable(label='Is In Diabetes Program' description='Indicates whether the patient is enrolled in an active Diabetes care program')
        public Boolean isInDiabetesProgram;

        @InvocableVariable(label='Error Message' description='Error message if processing failed for this patient (null if successful)')
        public String errorMessage;

        public AssessmentResult() {}
        public AssessmentResult(Id patientId) {
            this.patientId = patientId;
            this.isInDiabetesProgram = false;
            this.riskCategory = riskCategoryToString(RISK_CATEGORY.NO_DATA_AVAILABLE);
        }
    }

    /**
     * Invocable method that assesses diabetes care for a list of patients.
     *
     * Behavior:
     * - Validates input
     * - Resolves HbA1c CodeSet Id
     * - Retrieves latest HbA1c observation per patient
     * - Checks active Diabetes program enrollment
     * - Builds results with risk categorization and error handling per patient
     *
     * @param requests List of AssessmentRequest wrappers
     * @return List of AssessmentResult wrappers
     */
    @InvocableMethod(label='Assess Patient' description='Assesses patient diabetes care based on HbA1c values and program enrollment')
    public static List<AssessmentResult> assessPatient(List<AssessmentRequest> requests) {
        List<AssessmentResult> results = new List<AssessmentResult>();

        // 1) Input validation
        if (requests == null || requests.isEmpty()) {
            return results; // return-early
        }

        // 2) Extract Patient Ids and map to requests
        Set<Id> patientIds = new Set<Id>();
        Map<Id, AssessmentRequest> patientToRequest = new Map<Id, AssessmentRequest>();
        for (AssessmentRequest req : requests) {
            if (req != null && req.patientId != null) {
                patientIds.add(req.patientId);
                patientToRequest.put(req.patientId, req);
            }
        }

        // If no valid patient Ids, return empty result
        if (patientIds.isEmpty()) {
            return results; // return-early
        }

        // 3) HbA1c CodeSet Lookup
        Id hba1cCodeSetId = getHbA1cCodeSetId();
        if (hba1cCodeSetId == null) {
            // No HbA1c codeset - error for all patients
            for (Id pid : patientIds) {
                AssessmentResult er = new AssessmentResult(pid);
                er.errorMessage = 'HbA1c CodeSet not found in the system';
                // Keep default risk category as No Data Available
                results.add(er);
            }
            return results; // return-early
        }

        // 4) Data Retrieval
        Map<Id, CareObservation> latestObservationsByPatient = getLatestHbA1cObservations(patientIds, hba1cCodeSetId);
        Map<Id, Boolean> activeProgramByPatient = checkActiveDiabetesPrograms(patientIds);

        // 5) Result Processing
        for (Id pid : patientIds) {
            AssessmentResult r = new AssessmentResult(pid);
            try {
                CareObservation obs = latestObservationsByPatient.get(pid);
                if (obs != null && obs.ObservedValueNumerator != null) {
                    r.hba1cValue = obs.ObservedValueNumerator;

                    // Categorize risk
                    RISK_CATEGORY rc;
                    if (r.hba1cValue < 7.0) {
                        rc = RISK_CATEGORY.WELL_CONTROLLED;
                    } else if (r.hba1cValue >= 7.0 && r.hba1cValue < 9.0) {
                        rc = RISK_CATEGORY.NEEDS_ATTENTION;
                    } else {
                        rc = RISK_CATEGORY.HIGH_RISK_URGENT;
                    }
                    r.riskCategory = riskCategoryToString(rc);
                } else {
                    r.riskCategory = riskCategoryToString(RISK_CATEGORY.NO_DATA_AVAILABLE);
                }

                r.isInDiabetesProgram = activeProgramByPatient.containsKey(pid) ? activeProgramByPatient.get(pid) : false;

            } catch (Exception ex) {
                r.errorMessage = 'Error processing patient ' + String.valueOf(pid) + ': ' + ex.getMessage();
            }
            results.add(r);
        }

        // 6) Return
        return results;
    }

    /**
     * Retrieves the CodeSet Id for HbA1c.
     *
     * @return Id of CodeSet record named 'HbA1c', or null if not found
     */
    private static Id getHbA1cCodeSetId() {
        List<CodeSet> cs = [
            SELECT Id
            FROM CodeSet
            WHERE Name = 'HbA1c'
            WITH USER_MODE
            LIMIT 1
        ];
        return (cs.isEmpty() ? null : cs[0].Id);
    }

    /**
     * Retrieves the latest finalized HbA1c observation per patient (by EffectiveDateTime DESC).
     *
     * @param patientIds Set of patient/account Ids
     * @param hba1cCodeSetId Id of the HbA1c CodeSet
     * @return Map of Patient Id -> latest CareObservation
     */
    private static Map<Id, CareObservation> getLatestHbA1cObservations(Set<Id> patientIds, Id hba1cCodeSetId) {
        Map<Id, CareObservation> latestByPatient = new Map<Id, CareObservation>();
        if (patientIds == null || patientIds.isEmpty() || hba1cCodeSetId == null) {
            return latestByPatient; // return-early
        }

        List<CareObservation> obsList = [
            SELECT Id, ObservedSubjectId, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE CodeId = :hba1cCodeSetId
              AND ObservedSubjectId IN :patientIds
              AND ObservationStatus = 'Final'
              AND ObservedValueType = 'Quantity'
              AND ObservedValueNumerator != null
            WITH USER_MODE
            ORDER BY EffectiveDateTime DESC NULLS LAST
            LIMIT 1000
        ];

        for (CareObservation obs : obsList) {
            Id subjectId = obs.ObservedSubjectId;
            // Keep the first encountered per patient because list is DESC by EffectiveDateTime
            if (subjectId != null && !latestByPatient.containsKey(subjectId)) {
                latestByPatient.put(subjectId, obs);
            }
        }

        return latestByPatient;
    }

    /**
     * Determines which patients are enrolled in active Diabetes care programs.
     *
     * @param patientIds Set of patient/account Ids
     * @return Map of Patient Id -> Boolean (true if active enrollee in any Diabetes program)
     */
    private static Map<Id, Boolean> checkActiveDiabetesPrograms(Set<Id> patientIds) {
        Map<Id, Boolean> isEnrolled = new Map<Id, Boolean>();
        if (patientIds == null || patientIds.isEmpty()) {
            return isEnrolled; // return-early
        }

        // Initialize all as false
        for (Id pid : patientIds) {
            isEnrolled.put(pid, false);
        }

        // Subquery for Diabetes programs by name
        List<CareProgramEnrollee> enrollees = [
            SELECT Id, CareProgramId, AccountId, Status
            FROM CareProgramEnrollee
            WHERE AccountId IN :patientIds
              AND Status = 'Active'
              AND CareProgramId IN (
                  SELECT Id
                  FROM CareProgram
                  WHERE Name LIKE '%Diabetes%'
              )
            WITH USER_MODE
        ];

        for (CareProgramEnrollee e : enrollees) {
            if (e.AccountId != null) {
                isEnrolled.put(e.AccountId, true);
            }
        }

        return isEnrolled;
    }
}
