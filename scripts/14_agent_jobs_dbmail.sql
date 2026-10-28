/*******************************************************************************
 File    : 14_agent_jobs_dbmail.sql
 Purpose : SQL Agent job failures, running jobs, schedules, Database Mail.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] Managed Instance
           (Azure SQL DB has no SQL Agent - use Elastic Jobs / Automation.)
*******************************************************************************/

/*=============================================================================
  14.1 FAILED JOB STEPS - LAST N HOURS                                [BOX][MI]
=============================================================================*/
DECLARE @hours int = 24;
SELECT j.name AS job_name, h.step_id, h.step_name,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
       STUFF(STUFF(RIGHT('000000' + CAST(h.run_duration AS varchar(10)), 6), 5, 0, ':'), 3, 0, ':') AS duration_hhmmss,
       h.sql_message_id, h.sql_severity, h.message, h.server
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs       AS j ON j.job_id = h.job_id
WHERE h.run_status = 0                    -- 0 Failed 1 Succeeded 2 Retry 3 Canceled 4 In progress
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -@hours, GETDATE())
ORDER BY run_datetime DESC;


/*=============================================================================
  14.2 CURRENTLY RUNNING JOBS                                         [BOX][MI]
=============================================================================*/
SELECT j.name AS job_name, ja.start_execution_date,
       DATEDIFF(MINUTE, ja.start_execution_date, GETDATE()) AS running_minutes,
       ISNULL(ja.last_executed_step_id, 0) + 1              AS current_step_id,
       js.step_name AS current_step
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
LEFT JOIN msdb.dbo.sysjobsteps AS js ON js.job_id = ja.job_id AND js.step_id = ISNULL(ja.last_executed_step_id, 0) + 1
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
ORDER BY ja.start_execution_date;


/*=============================================================================
  14.3 JOB INVENTORY - OWNER, ENABLED, LAST OUTCOME, NEXT RUN         [BOX][MI]
=============================================================================*/
SELECT j.name AS job_name, j.enabled, SUSER_SNAME(j.owner_sid) AS owner_name,
       c.name AS category,
       CASE js.last_run_outcome WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded'
            WHEN 3 THEN 'Canceled' WHEN 5 THEN 'Unknown' END AS last_outcome,
       CASE WHEN js.last_run_date > 0 THEN msdb.dbo.agent_datetime(js.last_run_date, js.last_run_time) END AS last_run,
       (SELECT MIN(msdb.dbo.agent_datetime(s.next_run_date, s.next_run_time))
        FROM msdb.dbo.sysjobschedules AS s WHERE s.job_id = j.job_id AND s.next_run_date > 0) AS next_run,
       j.date_created, j.date_modified,
       CASE WHEN j.notify_level_email > 0 THEN 'Yes' ELSE 'No' END AS emails_on_failure
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysjobservers AS js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.syscategories AS c  ON c.category_id = j.category_id
ORDER BY j.name;


/*=============================================================================
  14.4 JOBS RUNNING LONGER THAN THEIR AVERAGE                         [BOX][MI]
=============================================================================*/
WITH avg_run AS (
    SELECT job_id,
           AVG((run_duration / 10000) * 3600 + (run_duration / 100 % 100) * 60 + run_duration % 100) AS avg_seconds
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0 AND run_status = 1
    GROUP BY job_id
)
SELECT j.name AS job_name, ja.start_execution_date,
       DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) AS running_seconds,
       a.avg_seconds,
       CAST(DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) * 1.0 / NULLIF(a.avg_seconds, 0) AS decimal(10,1)) AS times_avg
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j ON j.job_id = ja.job_id
LEFT JOIN avg_run AS a ON a.job_id = ja.job_id
WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL
ORDER BY times_avg DESC;


/*=============================================================================
  14.5 JOB STEP DETAILS (command, subsystem, proxy, database)          [BOX][MI]
=============================================================================*/
DECLARE @job sysname = N'%';   -- <== job name filter
SELECT j.name AS job_name, s.step_id, s.step_name, s.subsystem, s.database_name,
       s.command, s.on_success_action, s.on_fail_action, s.retry_attempts,
       p.name AS proxy_name, s.output_file_name
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysproxies AS p ON p.proxy_id = s.proxy_id
WHERE j.name LIKE @job
ORDER BY j.name, s.step_id;


/*=============================================================================
  14.6 JOBS OWNED BY INDIVIDUAL ACCOUNTS (break when person leaves)   [BOX][MI]
=============================================================================*/
SELECT j.name AS job_name, SUSER_SNAME(j.owner_sid) AS owner_name,
       N'EXEC msdb.dbo.sp_update_job @job_name = N''' + REPLACE(j.name, '''', '''''') + N''', @owner_login_name = N''sa'';' AS fix
FROM msdb.dbo.sysjobs AS j
WHERE SUSER_SNAME(j.owner_sid) <> N'sa' OR SUSER_SNAME(j.owner_sid) IS NULL;


/*=============================================================================
  14.7 AGENT SERVICE / ALERTS / OPERATORS                             [BOX][MI]
=============================================================================*/
SELECT name, enabled, email_address, last_email_date FROM msdb.dbo.sysoperators;
SELECT name, enabled, message_id, severity, last_occurrence_date, occurrence_count, has_notification
FROM msdb.dbo.sysalerts ORDER BY severity, message_id;


/*=============================================================================
  14.8 DATABASE MAIL - FAILURES & QUEUE                               [BOX][MI]
=============================================================================*/
SELECT TOP (50) mailitem_id, recipients, subject, sent_status, send_request_date, sent_date
FROM msdb.dbo.sysmail_allitems
WHERE sent_status <> 'sent'
ORDER BY send_request_date DESC;

SELECT TOP (50) log_id, event_type, log_date, description, mailitem_id
FROM msdb.dbo.sysmail_event_log
WHERE event_type IN ('error', 'warning')
ORDER BY log_date DESC;

-- EXEC msdb.dbo.sysmail_help_status_sp;   -- STARTED?
-- EXEC msdb.dbo.sysmail_start_sp;


/*=============================================================================
  14.9 START / STOP A JOB (templates)                                 [BOX][MI]
=============================================================================*/
-- EXEC msdb.dbo.sp_start_job @job_name = N'YourJob', @step_name = N'Step 2';
-- EXEC msdb.dbo.sp_stop_job  @job_name = N'YourJob';
