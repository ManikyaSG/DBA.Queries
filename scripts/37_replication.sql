/*******************************************************************************
 File    : 37_replication.sql
 Purpose : Transactional (and snapshot) replication health: topology, agent
           status, latency, undistributed commands, errors, finding and
           skipping the failing command, tracer tokens, distribution DB size.
 Tags    : [BOX] 2016-2025 / Azure VM   [MI] (publisher/distributor/subscriber)
           [SQLDB] push subscriber only
 Where   : Each section says where to run it: PUBLISHER (publication DB),
           DISTRIBUTOR (distribution DB) or SUBSCRIBER.
 Default distribution DB name = distribution (check 37.1).
*******************************************************************************/

/*=============================================================================
  37.1 ROLE OF THIS SERVER                                  (any)  [BOX][MI]
=============================================================================*/
SELECT name, is_published, is_merge_published, is_subscribed, is_distributor, log_reuse_wait_desc
FROM sys.databases
WHERE is_published = 1 OR is_merge_published = 1 OR is_subscribed = 1 OR is_distributor = 1;

EXEC sp_get_distributor;            -- is a distributor configured, which server, which DB
-- EXEC sp_helpdistributor;          -- more detail (run on publisher/distributor)


/*=============================================================================
  37.2 PUBLICATIONS & ARTICLES                    (PUBLISHER, publication DB) [BOX][MI]
=============================================================================*/
/*
USE [PublishedDB];
SELECT p.name AS publication, CASE p.repl_freq WHEN 0 THEN 'Transactional' ELSE 'Snapshot' END AS type,
       p.status, p.immediate_sync, p.allow_anonymous, COUNT(a.artid) AS articles
FROM dbo.syspublications AS p
LEFT JOIN dbo.sysarticles AS a ON a.pubid = p.pubid
GROUP BY p.name, p.repl_freq, p.status, p.immediate_sync, p.allow_anonymous;

SELECT p.name AS publication, a.name AS article, OBJECT_SCHEMA_NAME(a.objid) + '.' + OBJECT_NAME(a.objid) AS source_object, a.dest_table
FROM dbo.sysarticles AS a JOIN dbo.syspublications AS p ON p.pubid = a.pubid
ORDER BY publication, article;

EXEC sp_helpsubscription;            -- subscribers of each publication
*/


/*=============================================================================
  37.3 ONE-SHOT HEALTH: ALL SUBSCRIPTIONS, STATUS, LATENCY, PENDING  (DISTRIBUTOR) [BOX][MI]
  status: 1 Started 2 Succeeded 3 In progress 4 Idle 5 Retrying 6 Failed
  warning bits flag latency / expiration thresholds.
=============================================================================*/
/*
USE distribution;
EXEC sp_replmonitorhelpsubscription @publisher = NULL, @publication_type = 0;   -- 0 = transactional, 1 = snapshot, 2 = merge
EXEC sp_replmonitorhelppublication  @publisher = NULL;
*/


/*=============================================================================
  37.4 DISTRIBUTION AGENTS: LAST RUN STATUS, LATENCY, ERRORS  (DISTRIBUTOR) [BOX][MI]
=============================================================================*/
/*
USE distribution;
SELECT a.name AS agent_name, a.publisher_db, a.publication,
       ISNULL(srv.name, CAST(a.subscriber_id AS varchar(10))) AS subscriber, a.subscriber_db,
       CASE h.runstatus WHEN 1 THEN 'Started' WHEN 2 THEN 'Succeeded' WHEN 3 THEN 'In progress'
                        WHEN 4 THEN 'Idle' WHEN 5 THEN 'RETRYING' WHEN 6 THEN 'FAILED' END AS last_status,
       h.time AS last_message_time,
       h.delivery_latency / 1000.0 AS delivery_latency_s,
       h.delivered_commands, h.delivery_rate,
       h.comments
FROM dbo.MSdistribution_agents AS a
LEFT JOIN master.sys.servers AS srv ON srv.server_id = a.subscriber_id
OUTER APPLY (SELECT TOP (1) * FROM dbo.MSdistribution_history AS dh
             WHERE dh.agent_id = a.id ORDER BY dh.time DESC) AS h
ORDER BY CASE h.runstatus WHEN 6 THEN 0 WHEN 5 THEN 1 ELSE 2 END, agent_name;

-- Log Reader agents
SELECT a.name AS agent_name, a.publisher_db,
       CASE h.runstatus WHEN 1 THEN 'Started' WHEN 2 THEN 'Succeeded' WHEN 3 THEN 'In progress'
                        WHEN 4 THEN 'Idle' WHEN 5 THEN 'RETRYING' WHEN 6 THEN 'FAILED' END AS last_status,
       h.time, h.delivery_latency / 1000.0 AS latency_s, h.delivered_commands, h.comments
FROM dbo.MSlogreader_agents AS a
OUTER APPLY (SELECT TOP (1) * FROM dbo.MSlogreader_history AS lh WHERE lh.agent_id = a.id ORDER BY lh.time DESC) AS h;
*/


/*=============================================================================
  37.5 UNDISTRIBUTED COMMANDS (backlog per subscription)      (DISTRIBUTOR) [BOX][MI]
=============================================================================*/
/*
USE distribution;
SELECT a.name AS agent_name, a.publication, a.subscriber_db,
       SUM(s.UndelivCmdsInDistDB) AS pending_commands,
       SUM(s.DelivCmdsInDistDB)   AS delivered_commands_still_in_db
FROM dbo.MSdistribution_status AS s
JOIN dbo.MSdistribution_agents AS a ON a.id = s.agent_id
GROUP BY a.name, a.publication, a.subscriber_db
ORDER BY pending_commands DESC;

-- Pending commands + estimated time to catch up, one subscription:
EXEC sp_replmonitorsubscriptionpendingcmds
     @publisher = N'SQLPUB', @publisher_db = N'PublishedDB', @publication = N'PubName',
     @subscriber = N'SQLSUB', @subscriber_db = N'SubscriberDB', @subscription_type = 0;   -- 0 push, 1 pull
*/


/*=============================================================================
  37.6 REPLICATION ERRORS + THE FAILING COMMAND                 (DISTRIBUTOR) [BOX][MI]
  20598 = row not found at subscriber (UPDATE/DELETE)   2627/2601 = duplicate key (INSERT)
=============================================================================*/
/*
USE distribution;
SELECT TOP (50) e.time, e.error_code, e.error_text, e.xact_seqno, e.command_id, e.source_name
FROM dbo.MSrepl_errors AS e
ORDER BY e.time DESC;

-- Show the actual command that fails (use xact_seqno from above):
EXEC sp_browsereplcmds @xact_seqno_start = '0x0000002A000001B80003', @xact_seqno_end = '0x0000002A000001B80003';
-- (can be slow on a big distribution DB - always pass the seqno range)
*/


/*=============================================================================
  37.7 FIXING A STUCK SUBSCRIPTION (templates - decide carefully)           [BOX][MI]
=============================================================================*/
/*
 Option A - fix the data at the subscriber (insert the missing row / delete the duplicate),
            then restart the Distribution Agent. Best when it's one or two rows.
 Option B - skip known error types via agent profile (data drift accepted, investigate later):
            Replication Monitor > agent > Agent profiles > "Continue on data consistency errors"
            (-SkipErrors 2601:2627:20598)
 Option C - skip ONE transaction (run at SUBSCRIBER, in subscription DB):
            EXEC sp_setsubscriptionxactseqno @publisher = N'SQLPUB', @publisher_db = N'PublishedDB',
                 @publication = N'PubName', @xact_seqno = 0x0000002A000001B80004;   -- the NEXT seqno to apply
 Option D - reinitialize (new snapshot; heavy):
            PUBLISHER, publication DB:  EXEC sp_reinitsubscription @publication = N'PubName', @subscriber = N'SQLSUB', @destination_db = N'SubscriberDB';
                                        EXEC sp_startpublication_snapshot @publication = N'PubName';
 Afterwards: validate with  EXEC sp_publication_validation @publication = N'PubName', @rowcount_only = 1;  (PUBLISHER)
*/


/*=============================================================================
  37.8 TRACER TOKENS - MEASURE END-TO-END LATENCY            (PUBLISHER) [BOX][MI]
=============================================================================*/
/*
USE [PublishedDB];
EXEC sp_posttracertoken @publication = N'PubName';
-- wait a little, then:
EXEC sp_helptracertokens @publication = N'PubName';                         -- list tokens (tracer_id)
EXEC sp_helptracertokenhistory @publication = N'PubName', @tracer_id = -2147483641;
-- distributor_latency = publisher -> distributor (log reader); subscriber_latency = distributor -> subscriber
*/


/*=============================================================================
  37.9 LOG READER & PUBLISHER LOG                             (PUBLISHER) [BOX][MI]
  log_reuse_wait_desc = REPLICATION -> log reader behind or stopped.
=============================================================================*/
EXEC sp_replcounters;     -- per published DB: replicated transactions, rate (tran/s), latency (s)
-- DBCC OPENTRAN (N'PublishedDB');   -- shows "Oldest distributed LSN" / "Oldest non-distributed LSN"
-- Log full and log reader can't be fixed quickly (LAST RESORT - subscribers must be reinitialized):
--   EXEC sp_repldone @xactid = NULL, @xact_seqno = NULL, @numtrans = 0, @time = 0, @reset = 1;


/*=============================================================================
  37.10 DISTRIBUTION DB SIZE, RETENTION, CLEANUP              (DISTRIBUTOR) [BOX][MI]
=============================================================================*/
/*
USE distribution;
SELECT 'MSrepl_commands' AS table_name, SUM(p.rows) AS rows FROM sys.partitions p WHERE p.object_id = OBJECT_ID('dbo.MSrepl_commands') AND p.index_id IN (0,1)
UNION ALL
SELECT 'MSrepl_transactions', SUM(p.rows) FROM sys.partitions p WHERE p.object_id = OBJECT_ID('dbo.MSrepl_transactions') AND p.index_id IN (0,1);

EXEC sp_helpdistributiondb;            -- min/max retention (hours), history retention
-- Cleanup job: "Distribution clean up: distribution" must succeed (14_agent_jobs_dbmail.sql 14.1).
-- immediate_sync = 1 on a publication keeps ALL commands for max retention -> big distribution DB:
-- EXEC sp_changepublication @publication = N'PubName', @property = N'immediate_sync', @value = 'false';  (allow_anonymous first)
*/


/*=============================================================================
  37.11 REPLICATION + ALWAYS ON / MIGRATION NOTES
=============================================================================*/
/*
 - Publisher in an AG: configure a REMOTE distributor, redirect the publisher to the listener
   (sp_redirect_publisher), and check with sp_validate_replica_hosts_as_publishers.
 - Log reader won't read log not yet hardened on sync secondaries -> TF 1448 lets it run ahead of async ones.
 - Distribution DB itself can be in an AG (2017 CU6+ / 2016 SP2 CU3+).
 - Restoring a published DB elsewhere: RESTORE ... WITH KEEP_REPLICATION only if you know why;
   otherwise clean up with EXEC sp_removedbreplication @dbname = N'x';
*/
