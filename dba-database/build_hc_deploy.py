#!/usr/bin/env python3
"""
Builds DBAdmin_HC_Deploy.sql from the toolkit scripts.

Each numbered section (e.g. 2.1) of the selected scripts becomes one object in DBAdmin:
  * single SELECT, server scope, no inputs      -> VIEW                 SELECT * FROM dbo.HC_x
  * single SELECT, server scope, with inputs    -> inline TVF           SELECT * FROM dbo.HC_x(DEFAULT)
  * anything else, server scope                 -> PROCEDURE            EXEC dbo.HC_x
  * reads the current database's catalog        -> PROCEDURE that runs the query inside
                                                   @database_name       EXEC dbo.HC_x @database_name = N'Sales'
Views/TVFs fall back to a procedure at deploy time if SQL Server refuses them
(unnamed / duplicate columns etc.). Templates and change actions are skipped.

Usage:  python3 build_hc_deploy.py <scripts_dir> <output.sql> [report.tsv]
"""
import re, sys, glob, os

FILES = ['00','01','02','03','04','05','06','07','08','09','10','11','12','13','14','15',
         '16','17','18','19','20','21','22','23','24','25','26','31','36','39','40','41']

SKIP_TITLE = re.compile(r'TEMPLATE|CLEAR WAIT|REMOVE ONE BAD PLAN|RESIZE / ADD|START / STOP|RUN CHECKDB|'
    r'ENABLE / FIX|HISTORY CLEANUP|COMMON AG ACTIONS|NOTES|QUICK REFERENCE|KICK EVERYONE|MIGRATING LOGINS|'
    r'SHRINK / RESIZE|SET DATABASE OWNER|STOP / DROP|READ CHANGES|ENABLE / DISABLE|ADD / CHANGE / DROP|'
    r'TEST WHAT A USER|BEFORE / AFTER|BUILD AN AG|ADD / REMOVE|GARBAGE COLLECTION|SLA TABLE|'
    r'SCHEDULE IT|GENERATE THE STANDARD SET|THINGS THAT BEHAVE|CHEAT SHEET|LIVE PERFMON', re.I)

# hand-picked names where the auto slug is clumsy (section -> name without HC_)
NAMES = {
 '0.1':'version','0.2':'uptime_hardware','0.3':'host_os','0.4':'instance_settings',
 '0.5':'db_scoped_config','0.6':'trace_flags','0.7':'services','0.8':'database_properties',
 '0.9':'database_sizes','0.10':'connection_counts',
 '1.1':'top_waits','1.2':'waits_delta','1.3':'waiting_tasks','1.4':'session_waits',
 '1.5':'signal_waits','1.6':'latch_stats',
 '2.1':'active_sessions','2.2':'live_plan','2.3':'blocking_tree','2.4':'blocking_summary',
 '2.5':'open_transactions','2.6':'sleeping_open_trans','2.7':'connection_details',
 '2.8':'last_sql_by_session','2.9':'rollback_progress','2.10':'generate_kill_head_blockers',
 '3.1':'top_queries','3.2':'top_procedures','3.3':'top_query_hash','3.4':'param_sniffing_suspects',
 '3.5':'find_query_in_cache','3.6':'plan_cache_bloat','3.7':'plan_warnings','3.8':'compilations',
 '4.1':'qs_status','4.2':'qs_status_all_dbs','4.3':'qs_top_queries','4.4':'qs_regressed',
 '4.5':'qs_multi_plan','4.6':'qs_forced_plans','4.7':'qs_wait_categories','4.8':'qs_hints',
 '4.9':'qs_find_query',
 '5.1':'missing_indexes','5.2':'index_usage','5.3':'unused_indexes','5.4':'duplicate_indexes',
 '5.5':'index_fragmentation','5.6':'heaps_forwarded','5.7':'table_indexes','5.8':'stats_health',
 '5.9':'index_operational_stats','5.10':'columnstore_health','5.11':'tables_without_ci_pk',
 '5.12':'resumable_index_ops',
 '6.1':'memory_overview','6.2':'memory_counters','6.3':'ple_per_numa','6.4':'buffer_pool_by_db',
 '6.5':'buffer_pool_by_object','6.6':'memory_clerks','6.7':'memory_grants',
 '6.8':'low_memory_events','6.9':'oom_events','6.10':'memory_settings',
 '7.1':'cpu_history','7.2':'scheduler_pressure','7.3':'worker_threads','7.4':'top_cpu_now',
 '7.5':'cpu_by_database','7.6':'numa_maxdop',
 '8.1':'file_latency','8.2':'file_latency_delta','8.3':'pending_io','8.4':'volume_space',
 '8.5':'file_space','8.6':'file_space_all_dbs','8.7':'log_space','8.8':'log_stats',
 '8.9':'vlf_counts','8.10':'autogrowth_settings','8.11':'autogrowth_events','8.12':'largest_tables',
 '9.1':'tempdb_files','9.2':'tempdb_space','9.3':'tempdb_by_session','9.4':'version_store',
 '9.5':'snapshot_transactions','9.6':'tempdb_contention','9.7':'tempdb_metadata',
 '10.1':'last_backup','10.2':'backup_history','10.3':'backup_restore_progress',
 '10.4':'restore_history','10.5':'generate_restore_script','10.6':'backup_size_trend',
 '10.7':'backup_url_credentials','10.8':'sqldb_backups',
 '11.1':'ag_dashboard','11.2':'ag_replicas','11.3':'ag_db_sync','11.4':'ag_data_loss_window',
 '11.5':'ag_failover_readiness','11.6':'ag_helper_functions','11.7':'dbs_not_in_ag',
 '11.8':'ag_listeners','11.9':'ag_readonly_routing','11.10':'hadr_endpoint','11.11':'ag_seeding',
 '11.12':'wsfc','11.13':'ag_waits','11.14':'ag_failover_history',
 '12.1':'lock_summary','12.2':'waiting_locks','12.3':'session_locks','12.4':'lock_escalation',
 '12.5':'deadlocks','12.6':'deadlock_detail','12.7':'deadlock_count','12.8':'sqldb_deadlocks',
 '12.9':'isolation_levels',
 '13.1':'server_role_members','13.2':'logins','13.3':'weak_passwords','13.4':'risky_server_perms',
 '13.5':'orphaned_users','13.6':'db_role_members','13.7':'db_permissions',
 '13.8':'login_effective_perms','13.9':'guest_enabled','13.10':'risky_db_settings',
 '13.11':'tde_cert_expiry','13.12':'unencrypted_connections','13.13':'failed_logins',
 '13.14':'audit_status','13.15':'linked_servers','13.16':'sqldb_firewall_admins',
 '14.1':'failed_jobs','14.2':'running_jobs','14.3':'job_inventory','14.4':'long_running_jobs',
 '14.5':'job_steps','14.6':'jobs_owned_by_people','14.7':'agent_alerts_operators',
 '14.8':'dbmail_failures',
 '15.1':'dbs_not_online','15.2':'last_good_checkdb','15.3':'suspect_pages',
 '15.4':'ag_page_repair','15.5':'config_antipatterns','15.6':'errorlog_search',
 '15.7':'errorlog_files','15.8':'high_severity_errors','15.9':'server_diagnostics',
 '16.1':'sqldb_tier','16.2':'sqldb_resource_1h','16.3':'sqldb_resource_14d',
 '16.4':'sqldb_pool_usage','16.5':'sqldb_waits','16.6':'sqldb_space','16.7':'sqldb_geo_repl',
 '16.8':'sqldb_mgmt_ops','16.9':'sqldb_auto_tuning','16.10':'sqldb_connections',
 '16.11':'sqldb_pvs',
 '17.1':'mi_check','17.2':'mi_resource_history','17.3':'mi_governance','17.4':'mi_storage',
 '17.5':'mi_gp_file_perf','17.6':'mi_log_rate_waits','17.7':'mi_replica_state',
 '17.8':'mi_backup_history',
 '18.1':'xe_sessions','18.2':'xe_blocked_process','18.3':'xe_long_queries','18.4':'xe_errors',
 '18.5':'xe_sqldb_ring_buffer',
 '19.1':'generate_index_maint','19.2':'generate_stats_update','19.4':'find_object',
 '19.5':'find_column','19.6':'search_code','19.7':'row_counts','19.8':'recently_modified',
 '20.1':'v2017_features','20.2':'adr_status','20.3':'decode_page','20.4':'last_actual_plan',
 '20.5':'missing_index_queries','20.6':'iqp_settings','20.7':'contained_ags',
 '20.8':'psp_variants','20.9':'ledger_tables','20.10':'oom_events_2022',
 '20.11':'optimized_locking','20.12':'version_decoder',
 '21.1':'cdc_ct_databases','21.2':'cdc_tables','21.3':'cdc_columns','21.4':'cdc_schema_drift',
 '21.5':'cdc_latency','21.6':'cdc_errors','21.7':'cdc_jobs','21.8':'cdc_log_hold',
 '21.9':'cdc_table_sizes','21.13':'ct_tables',
 '22.1':'tde_status','22.2':'dbs_not_encrypted','22.3':'certificates','22.4':'master_keys',
 '22.5':'tde_progress','22.6':'encrypted_backups','22.7':'tde_cert_thumbprints','22.8':'ekm_akv',
 '22.9':'always_encrypted',
 '23.1':'masked_columns','23.2':'unmask_permissions','23.4':'unmasked_sensitive_cols',
 '23.6':'rls_policies','23.7':'data_classification','23.8':'protection_summary',
 '24.1':'missing_indexes_per_table','24.2':'index_column_map','24.3':'key_lookups',
 '24.4':'scans_in_cache','24.5':'fk_without_index','24.6':'clustered_key_review',
 '24.7':'over_indexed_tables','24.8':'page_splits','24.9':'fill_factors',
 '24.10':'compression_candidates','24.11':'partitions','24.12':'disabled_hypothetical_indexes',
 '24.13':'filtered_index_candidates',
 '25.1':'ag_alert','25.2':'ag_not_syncing_checklist','25.3':'ag_redo_blocked',
 '25.4':'ag_secondary_version_store','25.5':'ag_commit_latency','25.6':'distributed_ags',
 '25.7':'contained_ags_detail','25.8':'ag_login_drift','25.9':'ag_job_drift',
 '25.10':'ag_backup_preference',
 '26.1':'filestream_config','26.2':'filestream_dbs','26.3':'filestream_containers',
 '26.4':'filestream_columns','26.5':'filetables','26.6':'filetable_handles','26.8':'filestream_waits',
 '31.1':'schema_fingerprint','31.2':'compare_db_objects','31.3':'compare_db_columns',
 '31.4':'broken_objects','31.5':'constraint_integrity','31.6':'exact_row_counts',
 '31.7':'collation_mismatches','31.8':'column_type_mismatches','31.9':'identity_near_max',
 '31.10':'object_counts',
 '36.1':'failed_logins_decoded','36.2':'connectivity_ring_buffer','36.3':'auth_scheme_spn',
 '36.4':'listening_ports','36.5':'connection_storms','36.6':'linked_server_check','36.7':'dtc_orphans',
 '36.8':'service_broker','36.9':'stack_dumps_nonyield',
 '39.1':'stats_histogram','39.2':'ascending_key','39.3':'stats_past_threshold',
 '39.4':'est_vs_actual_rows','39.5':'parallelism','39.6':'compile_cost','39.7':'plan_guides',
 '39.8':'resource_governor','39.9':'inmemory_oltp','39.10':'spinlocks',
 '40.1':'rpo_rto_scorecard','40.2':'rpo_gaps','40.3':'broken_log_chains','40.4':'rogue_backups',
 '40.5':'backup_quality','40.6':'backup_files_exist','40.7':'restore_chain_length',
 '40.8':'crash_recovery_rto','40.9':'restore_tests','40.10':'ha_dr_coverage',
 '40.11':'ag_failover_rto',
 '41.1':'problems','41.2':'growth_forecast','41.3':'autogrowth_will_fail','41.5':'alerts_notify',
 '41.6':'restart_history','41.7':'config_changes',
}

# ---------------------------------------------------------------------------- lexer
def strip_comments(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":
            j = i + 1
            while j < n:
                if s[j] == "'" and j + 1 < n and s[j+1] == "'": j += 2; continue
                if s[j] == "'": break
                j += 1
            out.append(s[i:j+1]); i = j + 1
        elif c == '[':
            j = s.find(']', i); j = n - 1 if j < 0 else j
            out.append(s[i:j+1]); i = j + 1
        elif s.startswith('--', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if s.startswith('/*', j): depth += 1; j += 2
                elif s.startswith('*/', j): depth -= 1; j += 2
                else: j += 1
            out.append(' '); i = j
        else:
            out.append(c); i += 1
    txt = ''.join(out)
    txt = '\n'.join(l.rstrip() for l in txt.split('\n'))
    return re.sub(r'\n{3,}', '\n\n', txt).strip()

TOK = re.compile(r"N?'(?:[^']|'')*'|\[[^\]]*\]|@@?\w+|#\w+|\w+|\.|;|\(|\)|,|[^\s\w]", re.S)
def tokens(s):
    """(token_upper, start, end, depth)"""
    res, d = [], 0
    for m in TOK.finditer(s):
        t = m.group(0)
        if t == '(':
            res.append(('(', m.start(), m.end(), d)); d += 1; continue
        if t == ')':
            d -= 1; res.append((')', m.start(), m.end(), d)); continue
        res.append((t.upper() if not t.startswith(("'", "N'")) else t, m.start(), m.end(), d))
    return res

STMT_KW = {'DECLARE','SET','IF','WHILE','BEGIN','END','INSERT','UPDATE','DELETE','MERGE','EXEC','EXECUTE',
           'CREATE','DROP','ALTER','WAITFOR','TRUNCATE','PRINT','RAISERROR','THROW','FETCH','OPEN','CLOSE',
           'DEALLOCATE','KILL','DBCC','USE','BACKUP','RESTORE','RECONFIGURE','RETURN','GOTO','SHUTDOWN'}

def analyse(code):
    tk = tokens(code)
    info = {'stmt_kw': set(), 'selects': 0, 'option': False, 'forxml': False, 'into': False,
            'temp': bool(re.search(r'#\w', code)), 'vars': set(re.findall(r'(?<!@)@\w+', code))}
    prev = None; in_with = False; main_seen = False
    for idx, (t, s, e, d) in enumerate(tk):
        if d == 0:
            if t in STMT_KW:
                # SET inside UPDATE ... SET is not a statement; we never build views from UPDATEs anyway
                info['stmt_kw'].add(t)
            if t == 'WITH' and (prev in (None, ';') ):
                in_with = True; main_seen = False; info['selects'] += 1
            elif t == 'SELECT':
                if prev in ('UNION', 'ALL', 'EXCEPT', 'INTERSECT'):
                    pass
                elif in_with and not main_seen:
                    main_seen = True
                else:
                    in_with = False; info['selects'] += 1
            elif t == 'OPTION': info['option'] = True
            elif t == 'FOR' and idx + 1 < len(tk) and tk[idx+1][0] in ('XML', 'JSON', 'BROWSE'): info['forxml'] = True
            elif t == 'INTO': info['into'] = True
            elif t == ';': in_with = False
        prev = t if d == 0 else (prev if t != ')' or d else ')')
        if d == 0 and t == ')': prev = ')'
    return info, tk

def strip_order_by(code, tk):
    """Remove the final top-level ORDER BY unless the outer SELECT uses TOP."""
    top0 = [x for x in tk if x[3] == 0]
    obs = [i for i, x in enumerate(top0) if x[0] == 'ORDER' and i + 1 < len(top0) and top0[i+1][0] == 'BY']
    if not obs: return code.rstrip().rstrip(';').rstrip(), None
    # outer select = last top-level SELECT token that is not preceded by UNION etc.
    sels = [i for i, x in enumerate(top0) if x[0] == 'SELECT']
    last_sel = sels[-1] if sels else 0
    nxt = [x[0] for x in top0[last_sel+1:last_sel+3]]
    cut = top0[obs[-1]][1]
    if 'TOP' in nxt:   # keep it (it decides WHICH rows), but still offer it as a sort hint
        return code.rstrip().rstrip(';').rstrip(), '#' + code[cut:].strip().rstrip(';').strip()
    order_clause = code[cut:].strip().rstrip(';').strip()
    return code[:cut].rstrip().rstrip(';').rstrip(), order_clause

# ---------------------------------------------------------------------------- scope detection
DB_SCOPED = re.compile(r'(?<![\w\].])sys\.(objects|all_objects|tables|indexes|index_columns|columns|all_columns|stats|'
    r'stats_columns|schemas|partitions|allocation_units|database_principals|database_role_members|'
    r'database_permissions|database_files|filegroups|data_spaces|sql_modules|triggers|views|procedures|'
    r'foreign_keys|foreign_key_columns|types|query_store_\w+|database_query_store_options|'
    r'database_scoped_configurations|dm_db_partition_stats|dm_db_stats_properties\w*|dm_db_stats_histogram|'
    r'dm_db_column_store_row_group_physical_stats|column_store_row_groups|masked_columns|security_policies|'
    r'security_predicates|sensitivity_classifications|change_tracking_tables|plan_guides|dm_db_xtp_\w+|'
    r'certificates|symmetric_keys|asymmetric_keys|column_master_keys|column_encryption_keys|'
    r'database_audit_specifications|filetables|dm_db_resource_stats|dm_db_file_space_usage|'
    r'dm_db_log_space_usage|dm_db_persisted_sku_features|dm_database_encryption_keys_current|'
    r'database_service_objectives|dm_db_wait_stats|dm_db_tuning_recommendations|database_automatic_tuning_options|'
    r'dm_continuous_copy_status|dm_geo_replication_link_status|identity_columns|key_constraints|'
    r'default_constraints|check_constraints|sql_expression_dependencies|dm_sql_referenced_entities|'
    r'service_queues|transmission_queue|conversation_endpoints|routes|services|partition_functions|'
    r'partition_range_values|partition_schemes|ledger_\w+|database_ledger_\w+|extended_properties|'
    r'dm_cdc_\w+|dm_tran_persistent_version_store_stats|computed_columns|parameters|synonyms|'
    r'database_credentials|database_scoped_credentials|database_query_store_internal_state|'
    r'system_internals_\w+|internal_tables|fulltext_\w+|sequences|dm_db_xtp_\w+|memory_optimized_\w+)\b', re.I)
DB_FUNCS = re.compile(r'\bOBJECT_(?:SCHEMA_)?NAME\s*\(\s*[^,()]+(?:\([^()]*\))?\s*\)|\bDB_(?:ID|NAME)\s*\(\s*\)|'
    r'\bOBJECT_ID\s*\(\s*N?\'(?!tempdb|DBAdmin|msdb|master)|\bOBJECT_ID\s*\(\s*@|\bFILEPROPERTY\s*\(|\bINDEXPROPERTY\s*\(|'
    r'\bOBJECTPROPERTY(?:EX)?\s*\(|\bCOL_NAME\s*\(|\bCOLUMNPROPERTY\s*\(|\bSCHEMA_NAME\s*\(|'
    r'\bUSER_NAME\s*\(|\bDATABASE_PRINCIPAL_ID\s*\(|\bIS_ROLEMEMBER\s*\(|\bTYPE_NAME\s*\(|'
    r'\bsp_spaceused\b|\bcdc\.\w+|\bfn_my_permissions\b|\bINFORMATION_SCHEMA\.', re.I)

def is_db_scoped(code, title):
    if re.search(r'CURRENT DB|\(user DB\)|- THIS DATABASE', title, re.I): return True
    if re.search(r'ALL (ONLINE )?DATABASES|ACROSS ALL DATABASES|ON THE SAME INSTANCE|\(master\)', title, re.I): return False
    # strip strings that are dynamic SQL run per database (they are allowed to use db-scoped stuff)
    return db_scope_reason(code) is not None

def db_scope_reason(code):
    # blank out dynamic SQL strings (run per database on purpose); keep short literals like 'tempdb..#x'
    bare = re.sub(r"N?'(?:[^']|'')*'", lambda m: m.group(0) if len(m.group(0)) < 40 and '\n' not in m.group(0) else "''", code)
    m = DB_SCOPED.search(bare) or DB_FUNCS.search(bare)
    return m.group(0) if m else None

# ---------------------------------------------------------------------------- parameters
PARAM_DECL = re.compile(r"^DECLARE\s+(@\w+\s+[\w()., ]+?\s*=\s*(?:N?'(?:[^']|'')*'|-?\d+(?:\.\d+)?)"
                        r"(?:\s*,\s*@\w+\s+[\w()., ]+?\s*=\s*(?:N?'(?:[^']|'')*'|-?\d+(?:\.\d+)?))*)\s*;?[ \t]*$",
                        re.I | re.M)
def extract_params(code):
    """Leading-or-anywhere top-level DECLAREs with literal defaults -> parameters."""
    params, keep = [], []
    def take(m):
        for p in re.split(r",\s*(?=@)", m.group(1)):
            nm, rest = p.strip().split(None, 1)
            typ, val = [x.strip() for x in rest.split('=', 1)]
            if '(max)' in typ.lower() or nm.lower() in ('@sql', '@cmd'):
                keep.append(f'DECLARE {nm} {typ} = {val};'); continue
            params.append((nm, typ, val))
        return ''
    # multi-line DECLARE lists: join continuation lines first
    joined = re.sub(r"(DECLARE[^;]*?),\s*\n\s*(@)", r"\1, \2", code, flags=re.I)
    while True:
        new = re.sub(r"(DECLARE[^;\n]*?=\s*(?:N?'(?:[^']|'')*'|-?\d+(?:\.\d+)?)),\s*\n\s*(@)", r"\1, \2", joined, flags=re.I)
        if new == joined: break
        joined = new
    out = PARAM_DECL.sub(lambda m: (take(m), '\n'.join(keep))[1] if not keep.clear() else '', joined)
    return out.strip(), params

# ---------------------------------------------------------------------------- object builders
def q(s):  # escape for N'...'
    return s.replace("'", "''")

def slug(title):
    t = re.sub(r'\[[A-Z]+\]', '', title)
    t = re.sub(r'\(.*?\)|".*?"', '', t)
    t = re.sub(r'\b(CURRENT DB|ALL DATABASES|RIGHT NOW|THE|A|AN|OF|FOR|AND|WITH)\b', ' ', t, flags=re.I)
    t = re.sub(r'[^A-Za-z0-9]+', '_', t).strip('_').lower()
    return t[:40].rstrip('_')

def build(sec):
    code = sec['code']
    code, params = extract_params(code)
    for old, new in RENAME.items():
        if any(p[0] == old for p in params) and not any(p[0] == new for p in params):
            code = re.sub(re.escape(old) + r'\b', new, code)
            params = [(new if p[0] == old else p[0], p[1], p[2]) for p in params]
    info, tk = analyse(code)
    dbscoped = is_db_scoped(code, sec['title'])
    pnames = {p[0].lower() for p in params}
    other_vars = {v.lower() for v in info['vars']} - pnames
    simple = (info['selects'] == 1 and not info['stmt_kw'] and not info['option'] and not info['forxml']
              and not info['into'] and not info['temp'] and not other_vars)
    name = 'HC_' + NAMES.get(sec['num'], slug(sec['title']))
    proc_params = list(params)
    header = f"-- Toolkit {sec['file']} section {sec['num']}: {sec['title_clean']}\n"
    order = None
    if dbscoped:
        kind = 'P_DB'
        plist = ['@database_name sysname = NULL'] + [f'{n} {t} = {v}' for n, t, v in params]
        pdecl = ', '.join(f'{n} {t}' for n, t, v in params)
        passing = ', '.join(f'{n} = {n}' for n, t, v in params)
        body = (f"CREATE OR ALTER PROCEDURE dbo.{name}\n    " + ',\n    '.join(plist) + "\nAS\n" + header +
                "SET NOCOUNT ON;\n"
                "IF @database_name IS NULL AND CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 SET @database_name = DB_NAME();\n"
                "IF DB_ID(@database_name) IS NULL\n"
                "BEGIN RAISERROR(N'Pass @database_name = N''YourDB'' (an online database on this instance).', 16, 1); RETURN; END;\n"
                "DECLARE @hc_exec nvarchar(400) = QUOTENAME(@database_name) + N'.sys.sp_executesql';\n"
                f"DECLARE @hc_sql nvarchar(max) = N'{q(code)}';\n"
                + (f"EXEC @hc_exec @hc_sql, N'{q(pdecl)}', {passing};\n" if params else "EXEC @hc_exec @hc_sql;\n"))
        return dict(name=name, kind=kind, primary=body, fallback=None, params=params, order=None)
    proc_body = (f"CREATE OR ALTER PROCEDURE dbo.{name}" +
                 ("\n    " + ',\n    '.join(f'{n} {t} = {v}' for n, t, v in params) if params else '') +
                 "\nAS\n" + header + "SET NOCOUNT ON;\n" + code.rstrip().rstrip(';') + ";\n")
    if simple:
        vcode, order = strip_order_by(code, tk)
        vcode = vcode.lstrip(';').strip()
        kept = order is not None and order.startswith('#')
        if kept: order = order[1:]
        sel = [x for x in tk if x[3] == 0 and x[0] == 'SELECT']
        shift = len(code) - len(code.lstrip(';').lstrip())          # vcode lost a leading ';'
        outer = vcode[sel[-1][1] - shift:] if sel else vcode
        outer = re.sub(r'\bORDER\s+BY\b.*$', '', outer, flags=re.S | re.I) if kept else outer
        fo = friendly_order(order, outer)
        if kept: order = None
        if params:
            kind = 'IF'
            primary = (f"CREATE OR ALTER FUNCTION dbo.{name}\n(\n    " +
                       ',\n    '.join(f'{n} {t} = {v}' for n, t, v in params) +
                       "\n)\nRETURNS TABLE\nAS\n" + header + "RETURN\n(\n" + vcode + "\n);\n")
        else:
            kind = 'V'
            primary = f"CREATE OR ALTER VIEW dbo.{name}\nAS\n" + header + vcode + ";\n"
        return dict(name=name, kind=kind, primary=primary, fallback=proc_body, params=params, order=order,
                    friendly_order=fo)
    return dict(name=name, kind='P', primary=proc_body, fallback=None, params=params, order=None)

# ---------------------------------------------------------------------------- parse files
HDR = re.compile(r'/\*=+\s*\n\s+(\d+\.\d+)\s+(.*?)\n(.*?)=+\*/', re.S)
def sections(path):
    txt = open(path, encoding='utf-8-sig').read()
    ms = list(HDR.finditer(txt))
    for k, m in enumerate(ms):
        end = ms[k+1].start() if k + 1 < len(ms) else len(txt)
        title = m.group(2).strip()
        sub = m.group(3)
        tags = re.findall(r'\[(BOX|MI\*?|SQLDB)\]', title + ' ' + sub)
        tags = sorted({t.rstrip('*') for t in tags})
        title_clean = re.sub(r'\s*(\[[A-Z*]+\])+\s*$', '', re.sub(r'\s+', ' ', title)).strip()
        yield dict(file=os.path.basename(path), num=m.group(1), title=title, title_clean=title_clean,
                   tags=tags, code=strip_comments(txt[m.end():end]), note=re.sub(r'\s+', ' ', sub).strip())

MUTATE = re.compile(r'\b(ALTER|CREATE|DROP|KILL|DBCC\s+(?!TRACESTATUS|SQLPERF|LOGINFO|SHOW_STATISTICS|INPUTBUFFER|OPENTRAN|PAGE|IND)|'
                    r'UPDATE\s+(?!STATISTICS)|DELETE|INSERT|TRUNCATE|BACKUP|RESTORE\s+(?!HEADERONLY|FILELISTONLY|VERIFYONLY|LABELONLY)|'
                    r'RECONFIGURE|SHUTDOWN|sp_configure\s+N?\'|sp_start_job|sp_stop_job|sp_update_job|'
                    r'sp_cycle_errorlog|sp_add\w+|sp_delete\w+|sp_drop\w+|sp_change_users_login|sp_set_\w+)\b', re.I)

def mutates(code):
    bare = re.sub(r"N?'(?:[^']|'')*'", "''", code)
    # allow DDL / DML aimed at #temp tables and table variables
    bare = re.sub(r'\b(CREATE\s+TABLE|DROP\s+TABLE(\s+IF\s+EXISTS)?|INSERT(\s+INTO)?|UPDATE|DELETE(\s+FROM)?|TRUNCATE\s+TABLE|ALTER\s+TABLE)\s+[#@]\w+', ' ', bare, flags=re.I)
    bare = re.sub(r'\bIF\s+OBJECT_ID\s*\(\s*\'\'\s*\)\s*IS\s+NOT\s+NULL\s+DROP\s+TABLE\s+#\w+', ' ', bare, flags=re.I)
    bare = re.sub(r'\bDROP\s+TABLE\s+(IF\s+EXISTS\s+)?#\w+', ' ', bare, flags=re.I)
    m = MUTATE.search(bare)
    return m.group(0).strip() if m else None

def main(src, out, report=None):
    objs, skipped, seen = [], [], {}
    for f in FILES:
        path = glob.glob(os.path.join(src, f + '_*.sql'))[0]
        for sec in sections(path):
            ref = f"{sec['num']} {sec['title_clean']}"
            if SKIP_TITLE.search(sec['title']):
                skipped.append((sec['file'], sec['num'], sec['title_clean'], 'template / action')); continue
            if sec['num'] in CUSTOM: sec['code'] = CUSTOM[sec['num']]
            if not sec['code'].strip():
                skipped.append((sec['file'], sec['num'], sec['title_clean'], 'commented out in the script - run by hand')); continue
            mut = mutates(sec['code'])
            if mut and sec['num'] not in ALLOW_MUTATE:
                skipped.append((sec['file'], sec['num'], sec['title_clean'], f'changes something ({mut})')); continue
            o = build(sec)
            if o['name'] in seen:
                o['name'] += '_' + sec['num'].replace('.', '_')
            seen[o['name']] = 1
            o.update(sec=sec)
            objs.append(o)
    write_sql(objs, skipped, out)
    write_index(objs, skipped, os.path.join(os.path.dirname(os.path.abspath(out)), 'HC_OBJECTS.md'))
    if report:
        with open(report, 'w') as r:
            for o in objs:
                r.write(f"OBJ\t{o['sec']['num']}\t{o['kind']}\t{o['name']}\t{o['sec']['tags']}\t"
                        f"{','.join(p[0] for p in o['params'])}\t{o['sec']['title_clean']}\n")
            for s in skipped: r.write("SKIP\t" + '\t'.join(s) + '\n')
    print(len(objs), 'objects,', len(skipped), 'skipped')

ALLOW_MUTATE = set()

# friendlier parameter names
RENAME = {'@spid2': '@spid', '@hrs': '@hours', '@tbl': '@table', '@obj': '@object_name',
          '@SortBy': '@sort_by', '@Top': '@top', '@qid': '@query_id', '@db': '@database',
          '@search': '@search_text', '@job': '@job_name', '@src': '@source_db', '@tgt': '@target_db'}

# sections whose toolkit text is a one-liner with literals - give them real inputs
CUSTOM = {
 '4.9':  "DECLARE @search_text nvarchar(400) = N'%YourText%';\n"
         "SELECT q.query_id, q.last_execution_time, OBJECT_NAME(q.object_id) AS object_name, qt.query_sql_text\n"
         "FROM sys.query_store_query      AS q\n"
         "JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id\n"
         "WHERE qt.query_sql_text LIKE @search_text\n"
         "ORDER BY q.last_execution_time DESC;",
 '13.13': "DECLARE @log_number int = 0;\nEXEC sys.xp_readerrorlog @log_number, 1, N'Login failed';",
 '15.6':  "DECLARE @log_number int = 0;\nDECLARE @search_text nvarchar(200) = N'error';\n"
          "DECLARE @search_text2 nvarchar(200) = N'';\n"
          "EXEC sys.xp_readerrorlog @log_number, 1, @search_text, @search_text2;",
}   # sections reviewed by hand and known to only touch #temp / generate text

def write_sql(objs, skipped, out):
    L = []
    L.append(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'deploy_header.sql')).read())
    for o in objs:
        s = o['sec']
        usage = usage_of(o)
        L.append(f"\n/* {s['num']}  {s['title_clean']}   ({s['file']}) */\n")
        L.append("EXEC dbo.HC_usp_deploy\n"
                 f"    @name = N'{o['name']}', @section = N'{s['num']}', @source_file = N'{s['file']}',\n"
                 f"    @title = N'{q(s['title_clean'])}', @tags = N'{','.join(s['tags'])}',\n"
                 f"    @usage = N'{q(usage)}',\n"
                 f"    @min_version = {min_version(s) or 'NULL'},\n"
                 f"    @sort_hint = {('N' + chr(39) + q(o['order']) + chr(39)) if o['order'] else 'NULL'},\n"
                 f"    @definition = N'{q(o['primary'])}',\n"
                 f"    @fallback_definition = {('N' + chr(39) + q(o['fallback']) + chr(39)) if o['fallback'] else 'NULL'};\nGO\n")
    L.append(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'deploy_footer.sql')).read())
    with open(out, 'w', encoding='utf-8', newline='\r\n') as fh:
        fh.write(''.join(L))

def friendly_order(order, code):
    """Turn 'ORDER BY r.total_elapsed_time DESC' into 'ORDER BY elapsed_s DESC' using the view's output names.
    Returns None if any item can't be mapped to an output column."""
    if not order: return None
    body = order[len('ORDER BY'):].strip()
    items, d, cur = [], 0, ''
    for ch in body:
        if ch == '(': d += 1
        if ch == ')': d -= 1
        if ch == ',' and d == 0: items.append(cur.strip()); cur = ''; continue
        cur += ch
    items.append(cur.strip())
    out = []
    for it in items:
        m = re.match(r'^(.*?)(\s+(ASC|DESC))?$', it, re.I | re.S)
        expr, dirn = m.group(1).strip(), (m.group(2) or '')
        col = re.sub(r'^\w+\.', '', expr).strip('[]')
        if not re.match(r'^\w+$', col):
            return None
        if re.search(r'\bAS\s+\[?' + re.escape(col) + r'\]?\s*(,|$)', code, re.I | re.M):
            out.append(col + dirn); continue
        al = re.search(r'(?<![\w@.])' + re.escape(expr) + r'\s+AS\s+\[?(\w+)', code, re.I)
        if al:
            out.append(al.group(1) + dirn); continue
        line = next((l for l in code.split('\n') if re.search(r'(?<![\w@.])' + re.escape(expr) + r'\b', l)), None)
        al = re.findall(r'\bAS\s+\[?(\w+)\]?\s*,?\s*$', line or '', re.I)
        if line and len(re.findall(r'\bAS\b', line, re.I)) == 1 and al:
            out.append(al[0] + dirn); continue
        if re.search(r'(?<![\w@.])' + re.escape(expr) + r'\s*(,|\n|$)', code):
            out.append(col + dirn); continue
        return None
    return 'ORDER BY ' + ', '.join(out)

def min_version(sec):
    t = sec['title']   # notes mention versions for single columns; only the title gates the object
    if re.search(r'Azure SQL DB, MI|\(Azure', t) and not re.search(r'20\d\d', t): return None
    m = re.search(r'\b(2017|2019|2022|2025)\s*\+|\b(2017|2019|2022|2025)\s+and later|^\s*(2017|2019|2022|2025)\b', t)
    if not m or re.search(r'\b2016\b', t):   # '2016 SP2+ / 2017+' -> works on 2016 already
        return None
    y = next(g for g in m.groups() if g)
    return {'2017': 14, '2019': 15, '2022': 16, '2025': 17}[y]

def write_index(objs, skipped, path):
    kinds = {'V': 'view', 'IF': 'function', 'P': 'procedure', 'P_DB': 'procedure (per database)'}
    L = ['# HC_ objects in DBAdmin', '',
         'Generated by `build_hc_deploy.py`. On any server: `SELECT * FROM DBAdmin.dbo.HC_catalog;` shows what is',
         'actually installed there (some objects are skipped on older versions or other platforms).', '',
         f'{len(objs)} objects, built from the toolkit sections listed below.', '']
    cur = None
    for o in objs:
        s = o['sec']
        if s['file'] != cur:
            cur = s['file']; L += ['', f'## {cur}', '', '| § | Object | Type | How to run |', '|---|---|---|---|']
        L.append(f"| {s['num']} | `{o['name']}` | {kinds[o['kind']]} | `{usage_of(o).replace('|', '/')}` |")
    L += ['', '## Not converted (templates or actions you should run by hand from the script)', '',
          '| File | § | Section | Why |', '|---|---|---|---|']
    for f, n, t, why in skipped:
        L.append(f'| {f} | {n} | {t} | {why} |')
    L += ['', 'Runbook files not converted at all (step-by-step procedures, not health checks): '
          '27, 28, 29, 30, 32, 33, 34, 35, 37, 38, 42, 43, 44.', '']
    open(path, 'w', encoding='utf-8').write('\n'.join(L))

def usage_of(o):
    n, ps = o['name'], o['params']
    srt = (' ' + o['friendly_order']) if o.get('friendly_order') else ''
    if o['kind'] == 'V': return f"SELECT * FROM dbo.{n}{srt};"
    if o['kind'] == 'IF':
        return f"SELECT * FROM dbo.{n}({', '.join('DEFAULT' for _ in ps)}){srt};  -- " + ', '.join(f'{p[0]} = {p[2]}' for p in ps)
    if o['kind'] == 'P_DB':
        extra = ''.join(f", {p[0]} = {p[2]}" for p in ps)
        return f"EXEC dbo.{n} @database_name = N'YourDB'{extra};"
    return f"EXEC dbo.{n}" + (' ' + ', '.join(f'{p[0]} = {p[2]}' for p in ps) if ps else '') + ';'

if __name__ == '__main__':
    main(*sys.argv[1:])
