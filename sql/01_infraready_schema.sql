-- InfraReady application schema v3 (23-table full bootstrap)
-- Target: MariaDB 11.8 / database: infraready
-- Run once on the current writable Primary only. Replication applies it to the Replica.

CREATE DATABASE IF NOT EXISTS infraready
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_uca1400_ai_ci;

USE infraready;

CREATE TABLE users (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email VARCHAR(254) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  nickname VARCHAR(50) NOT NULL,
  account_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_users_email (email),
  CONSTRAINT chk_users_status
    CHECK (account_status IN ('ACTIVE', 'LOCKED', 'WITHDRAWN'))
) ENGINE=InnoDB;

CREATE TABLE jwt_sessions (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  token_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  refresh_token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
  issued_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  expires_at DATETIME(6) NOT NULL,
  revoked_at DATETIME(6) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_jwt_sessions_token_id (token_id),
  KEY idx_jwt_sessions_user_active (user_id, revoked_at, expires_at),
  CONSTRAINT fk_jwt_sessions_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT chk_jwt_sessions_expiry CHECK (expires_at > issued_at)
) ENGINE=InnoDB;

CREATE TABLE subjects (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  name VARCHAR(100) NOT NULL,
  is_active TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_subjects_code (code),
  CONSTRAINT chk_subjects_active CHECK (is_active IN (0, 1))
) ENGINE=InnoDB;

CREATE TABLE user_subjects (
  user_id BIGINT UNSIGNED NOT NULL,
  slot_no TINYINT UNSIGNED NOT NULL,
  subject_id BIGINT UNSIGNED NOT NULL,
  learning_level VARCHAR(20) NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id, slot_no),
  UNIQUE KEY uk_user_subjects_user_subject (user_id, subject_id),
  KEY idx_user_subjects_subject (subject_id),
  CONSTRAINT fk_user_subjects_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_user_subjects_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE RESTRICT,
  CONSTRAINT chk_user_subjects_slot CHECK (slot_no BETWEEN 1 AND 3),
  CONSTRAINT chk_user_subjects_level
    CHECK (learning_level IN ('BEGINNER', 'INTERMEDIATE', 'ADVANCED'))
) ENGINE=InnoDB;

CREATE TABLE daily_plans (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  subject_id BIGINT UNSIGNED NOT NULL,
  plan_date DATE NOT NULL,
  title VARCHAR(200) NOT NULL,
  plan_status VARCHAR(20) NOT NULL DEFAULT 'READY',
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY idx_daily_plans_user_date (user_id, plan_date),
  KEY idx_daily_plans_subject_date (subject_id, plan_date),
  CONSTRAINT fk_daily_plans_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_daily_plans_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE RESTRICT,
  CONSTRAINT chk_daily_plans_status
    CHECK (plan_status IN ('READY', 'IN_PROGRESS', 'COMPLETED'))
) ENGINE=InnoDB;

CREATE TABLE plan_steps (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  plan_id BIGINT UNSIGNED NOT NULL,
  step_no TINYINT UNSIGNED NOT NULL,
  title VARCHAR(200) NOT NULL,
  content TEXT NULL,
  step_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  completed_at DATETIME(6) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_plan_steps_plan_step (plan_id, step_no),
  KEY idx_plan_steps_plan_status (plan_id, step_status),
  CONSTRAINT fk_plan_steps_plan
    FOREIGN KEY (plan_id) REFERENCES daily_plans (id) ON DELETE CASCADE,
  CONSTRAINT chk_plan_steps_no CHECK (step_no BETWEEN 1 AND 3),
  CONSTRAINT chk_plan_steps_status
    CHECK (step_status IN ('PENDING', 'IN_PROGRESS', 'COMPLETED'))
) ENGINE=InnoDB;

CREATE TABLE diagnosis_questions (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  subject_id BIGINT UNSIGNED NOT NULL,
  question_no SMALLINT UNSIGNED NOT NULL,
  difficulty VARCHAR(20) NOT NULL,
  question_text TEXT NOT NULL,
  content_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
  explanation TEXT NOT NULL,
  is_active TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_questions_subject_no (subject_id, question_no),
  UNIQUE KEY uk_questions_subject_content_hash (subject_id, content_hash),
  KEY idx_questions_subject_active (subject_id, is_active),
  CONSTRAINT fk_questions_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE RESTRICT,
  CONSTRAINT chk_questions_no CHECK (question_no BETWEEN 1 AND 1000),
  CONSTRAINT chk_questions_difficulty
    CHECK (difficulty IN ('BEGINNER', 'INTERMEDIATE', 'ADVANCED')),
  CONSTRAINT chk_questions_active CHECK (is_active IN (0, 1))
) ENGINE=InnoDB;

CREATE TABLE question_options (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  question_id BIGINT UNSIGNED NOT NULL,
  option_no TINYINT UNSIGNED NOT NULL,
  option_text VARCHAR(1000) NOT NULL,
  is_correct TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  UNIQUE KEY uk_question_options_question_no (question_id, option_no),
  UNIQUE KEY uk_question_options_question_id (question_id, id),
  CONSTRAINT fk_question_options_question
    FOREIGN KEY (question_id) REFERENCES diagnosis_questions (id)
      ON DELETE CASCADE,
  CONSTRAINT chk_question_options_no CHECK (option_no BETWEEN 1 AND 5),
  CONSTRAINT chk_question_options_correct CHECK (is_correct IN (0, 1))
) ENGINE=InnoDB;

CREATE TABLE diagnosis_attempts (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  subject_id BIGINT UNSIGNED NOT NULL,
  attempt_type VARCHAR(20) NOT NULL DEFAULT 'DIAGNOSTIC',
  attempt_status VARCHAR(20) NOT NULL DEFAULT 'IN_PROGRESS',
  total_questions TINYINT UNSIGNED NOT NULL,
  correct_answers TINYINT UNSIGNED NOT NULL DEFAULT 0,
  started_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  completed_at DATETIME(6) NULL,
  PRIMARY KEY (id),
  KEY idx_attempts_user_started (user_id, started_at),
  KEY idx_attempts_subject_started (subject_id, started_at),
  CONSTRAINT fk_attempts_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_attempts_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE RESTRICT,
  CONSTRAINT chk_attempts_type
    CHECK (attempt_type IN ('DIAGNOSTIC', 'RELEARN')),
  CONSTRAINT chk_attempts_status
    CHECK (attempt_status IN ('IN_PROGRESS', 'COMPLETED', 'ABANDONED')),
  CONSTRAINT chk_attempts_total CHECK (total_questions BETWEEN 5 AND 10),
  CONSTRAINT chk_attempts_correct
    CHECK (correct_answers <= total_questions)
) ENGINE=InnoDB;

CREATE TABLE diagnosis_answers (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  attempt_id BIGINT UNSIGNED NOT NULL,
  question_id BIGINT UNSIGNED NOT NULL,
  selected_option_id BIGINT UNSIGNED NOT NULL,
  is_correct TINYINT(1) NOT NULL,
  answered_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_answers_attempt_question (attempt_id, question_id),
  KEY idx_answers_question (question_id),
  KEY idx_answers_selected_option (question_id, selected_option_id),
  CONSTRAINT fk_answers_attempt
    FOREIGN KEY (attempt_id) REFERENCES diagnosis_attempts (id)
      ON DELETE CASCADE,
  CONSTRAINT fk_answers_selected_option
    FOREIGN KEY (question_id, selected_option_id)
      REFERENCES question_options (question_id, id) ON DELETE RESTRICT,
  CONSTRAINT chk_answers_correct CHECK (is_correct IN (0, 1))
) ENGINE=InnoDB;

CREATE TABLE wrong_notes (
  user_id BIGINT UNSIGNED NOT NULL,
  question_id BIGINT UNSIGNED NOT NULL,
  last_attempt_id BIGINT UNSIGNED NULL,
  wrong_count INT UNSIGNED NOT NULL DEFAULT 1,
  is_relearned TINYINT(1) NOT NULL DEFAULT 0,
  first_wrong_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  last_wrong_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  relearned_at DATETIME(6) NULL,
  PRIMARY KEY (user_id, question_id),
  KEY idx_wrong_notes_user_relearned (user_id, is_relearned, last_wrong_at),
  KEY idx_wrong_notes_attempt (last_attempt_id),
  CONSTRAINT fk_wrong_notes_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_wrong_notes_question
    FOREIGN KEY (question_id) REFERENCES diagnosis_questions (id)
      ON DELETE RESTRICT,
  CONSTRAINT fk_wrong_notes_attempt
    FOREIGN KEY (last_attempt_id) REFERENCES diagnosis_attempts (id)
      ON DELETE SET NULL,
  CONSTRAINT chk_wrong_notes_count CHECK (wrong_count >= 1),
  CONSTRAINT chk_wrong_notes_relearned CHECK (is_relearned IN (0, 1))
) ENGINE=InnoDB;

CREATE TABLE study_daily_stats (
  user_id BIGINT UNSIGNED NOT NULL,
  study_date DATE NOT NULL,
  solved_count INT UNSIGNED NOT NULL DEFAULT 0,
  correct_count INT UNSIGNED NOT NULL DEFAULT 0,
  completed_step_count TINYINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id, study_date),
  CONSTRAINT fk_study_daily_stats_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT chk_study_daily_stats_correct
    CHECK (correct_count <= solved_count),
  CONSTRAINT chk_study_daily_stats_steps
    CHECK (completed_step_count BETWEEN 0 AND 3)
) ENGINE=InnoDB;

CREATE TABLE ai_generation_runs (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  subject_id BIGINT UNSIGNED NULL,
  request_type VARCHAR(30) NOT NULL,
  provider VARCHAR(30) NOT NULL,
  model_name VARCHAR(100) NOT NULL,
  prompt_version VARCHAR(30) NOT NULL,
  generation_status VARCHAR(20) NOT NULL DEFAULT 'RUNNING',
  provider_request_id VARCHAR(128) NULL,
  input_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  input_tokens INT UNSIGNED NULL,
  output_tokens INT UNSIGNED NULL,
  provider_usage_units DECIMAL(20,6) NULL,
  provider_usage_unit VARCHAR(20) NULL,
  latency_ms INT UNSIGNED NULL,
  http_status SMALLINT UNSIGNED NULL,
  output_json JSON NULL,
  error_code VARCHAR(50) NULL,
  error_message VARCHAR(500) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  completed_at DATETIME(6) NULL,
  PRIMARY KEY (id),
  KEY idx_ai_runs_user_created (user_id, created_at),
  KEY idx_ai_runs_status_created (generation_status, created_at),
  KEY idx_ai_runs_type_subject_created
    (request_type, subject_id, created_at),
  KEY idx_ai_runs_input_hash (input_hash),
  KEY idx_ai_runs_provider_request (provider_request_id),
  CONSTRAINT fk_ai_runs_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_ai_runs_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE SET NULL,
  CONSTRAINT chk_ai_runs_request_type
    CHECK (request_type IN
      ('PLAN', 'WRONG_FEEDBACK', 'WEEKLY_INSIGHT', 'QUESTION_DRAFT')),
  CONSTRAINT chk_ai_runs_provider
    CHECK (provider IN ('GROQ', 'CLOUDFLARE', 'GEMINI')),
  CONSTRAINT chk_ai_runs_status
    CHECK (generation_status IN
      ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'FALLBACK')),
  CONSTRAINT chk_ai_runs_http_status
    CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  CONSTRAINT chk_ai_generation_provider_unit
    CHECK (
      provider_usage_unit IS NULL
      OR provider_usage_unit IN ('NEURONS', 'TOKENS')
    )
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE user_ai_preferences (
  user_id BIGINT UNSIGNED NOT NULL,
  ai_enabled TINYINT(1) NOT NULL DEFAULT 0,
  ai_consent_at DATETIME(6) NULL,
  privacy_notice_version VARCHAR(30) NULL,
  explanation_style VARCHAR(20) NOT NULL DEFAULT 'BRIEF',
  available_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 30,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id),
  CONSTRAINT fk_user_ai_preferences_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT chk_user_ai_preferences_enabled
    CHECK (ai_enabled IN (0, 1)),
  CONSTRAINT chk_user_ai_preferences_style
    CHECK (explanation_style IN ('BRIEF', 'DETAILED', 'PRACTICAL')),
  CONSTRAINT chk_user_ai_preferences_minutes
    CHECK (available_minutes BETWEEN 5 AND 240)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE daily_plan_ai_meta (
  plan_id BIGINT UNSIGNED NOT NULL,
  generation_run_id BIGINT UNSIGNED NOT NULL,
  rationale TEXT NOT NULL,
  criteria_json JSON NULL,
  generated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (plan_id),
  UNIQUE KEY uk_daily_plan_ai_meta_generation (generation_run_id),
  CONSTRAINT fk_daily_plan_ai_meta_plan
    FOREIGN KEY (plan_id) REFERENCES daily_plans (id) ON DELETE CASCADE,
  CONSTRAINT fk_daily_plan_ai_meta_generation
    FOREIGN KEY (generation_run_id) REFERENCES ai_generation_runs (id)
      ON DELETE RESTRICT
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE wrong_note_ai_feedback (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  question_id BIGINT UNSIGNED NOT NULL,
  generation_run_id BIGINT UNSIGNED NOT NULL,
  feedback_text TEXT NOT NULL,
  recommended_action_json JSON NULL,
  feedback_status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  applied_at DATETIME(6) NULL,
  PRIMARY KEY (id),
  KEY idx_wrong_note_ai_user_question_created
    (user_id, question_id, created_at),
  KEY idx_wrong_note_ai_user_status (user_id, feedback_status),
  KEY idx_wrong_note_ai_generation (generation_run_id),
  CONSTRAINT fk_wrong_note_ai_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_wrong_note_ai_question
    FOREIGN KEY (question_id) REFERENCES diagnosis_questions (id)
      ON DELETE CASCADE,
  CONSTRAINT fk_wrong_note_ai_generation
    FOREIGN KEY (generation_run_id) REFERENCES ai_generation_runs (id)
      ON DELETE RESTRICT,
  CONSTRAINT chk_wrong_note_ai_status
    CHECK (feedback_status IN ('ACTIVE', 'SUPERSEDED', 'APPLIED'))
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE next_plan_queue (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  subject_id BIGINT UNSIGNED NOT NULL,
  source_type VARCHAR(30) NOT NULL,
  source_id BIGINT UNSIGNED NULL,
  title VARCHAR(200) NOT NULL,
  content TEXT NOT NULL,
  priority TINYINT UNSIGNED NOT NULL DEFAULT 3,
  queue_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  applied_plan_id BIGINT UNSIGNED NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  applied_at DATETIME(6) NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY idx_next_plan_queue_user_status_priority_created
    (user_id, queue_status, priority, created_at),
  KEY idx_next_plan_queue_subject_status (subject_id, queue_status),
  KEY idx_next_plan_queue_applied_plan (applied_plan_id),
  KEY idx_next_plan_queue_source (source_type, source_id),
  CONSTRAINT fk_next_plan_queue_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_next_plan_queue_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE RESTRICT,
  CONSTRAINT fk_next_plan_queue_applied_plan
    FOREIGN KEY (applied_plan_id) REFERENCES daily_plans (id)
      ON DELETE SET NULL,
  CONSTRAINT chk_next_plan_queue_source_type
    CHECK (source_type IN
      ('WRONG_NOTE', 'DIAGNOSIS', 'USER_REQUEST', 'AI_RECOMMENDATION')),
  CONSTRAINT chk_next_plan_queue_priority
    CHECK (priority BETWEEN 1 AND 5),
  CONSTRAINT chk_next_plan_queue_status
    CHECK (queue_status IN ('PENDING', 'APPLIED', 'DISMISSED'))
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE ai_token_quotas (
  user_id BIGINT UNSIGNED NOT NULL,
  daily_token_limit INT UNSIGNED NOT NULL DEFAULT 5000,
  monthly_token_limit INT UNSIGNED NULL,
  is_enabled TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id),
  CONSTRAINT fk_ai_token_quotas_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT chk_ai_token_quotas_enabled
    CHECK (is_enabled IN (0, 1)),
  CONSTRAINT chk_ai_token_quotas_daily
    CHECK (daily_token_limit > 0),
  CONSTRAINT chk_ai_token_quotas_monthly
    CHECK (
      monthly_token_limit IS NULL
      OR monthly_token_limit >= daily_token_limit
    )
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE ai_token_ledger (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  generation_run_id BIGINT UNSIGNED NULL,
  entry_type VARCHAR(20) NOT NULL,
  token_delta INT NOT NULL,
  input_tokens INT UNSIGNED NULL,
  output_tokens INT UNSIGNED NULL,
  provider_usage_units DECIMAL(20,6) NULL,
  provider_usage_unit VARCHAR(20) NULL,
  description VARCHAR(200) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  UNIQUE KEY uk_ai_token_ledger_run_type
    (generation_run_id, entry_type),
  KEY idx_ai_token_ledger_user_created (user_id, created_at),
  CONSTRAINT fk_ai_token_ledger_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_ai_token_ledger_generation
    FOREIGN KEY (generation_run_id) REFERENCES ai_generation_runs (id)
      ON DELETE CASCADE,
  CONSTRAINT chk_ai_token_ledger_type
    CHECK (entry_type IN ('USAGE', 'REFUND', 'ADMIN_ADJUST')),
  CONSTRAINT chk_ai_token_ledger_delta
    CHECK (
      (entry_type = 'USAGE' AND token_delta > 0)
      OR (entry_type = 'REFUND' AND token_delta < 0)
      OR (entry_type = 'ADMIN_ADJUST' AND token_delta <> 0)
    ),
  CONSTRAINT chk_ai_token_ledger_provider_unit
    CHECK (
      provider_usage_unit IS NULL
      OR provider_usage_unit IN ('NEURONS', 'TOKENS')
    )
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE user_notifications (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id BIGINT UNSIGNED NOT NULL,
  notification_type VARCHAR(30) NOT NULL,
  source_key VARCHAR(100) NULL,
  title VARCHAR(200) NOT NULL,
  message VARCHAR(500) NOT NULL,
  target_page VARCHAR(30) NOT NULL DEFAULT 'dashboard',
  is_read TINYINT(1) NOT NULL DEFAULT 0,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  read_at DATETIME(6) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_notifications_user_source (user_id, source_key),
  KEY ix_notifications_user_read_created (user_id, is_read, created_at),
  CONSTRAINT fk_notifications_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT chk_notifications_read CHECK (is_read IN (0, 1))
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE question_reports (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  reporter_user_id BIGINT UNSIGNED NOT NULL,
  question_id BIGINT UNSIGNED NOT NULL,
  report_type VARCHAR(30) NOT NULL,
  detail VARCHAR(500) NULL,
  report_status VARCHAR(20) NOT NULL DEFAULT 'OPEN',
  resolution_note VARCHAR(500) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  resolved_at DATETIME(6) NULL,
  resolved_by_user_id BIGINT UNSIGNED NULL,
  PRIMARY KEY (id),
  KEY ix_reports_status_created (report_status, created_at),
  KEY ix_reports_question (question_id),
  KEY ix_reports_reporter_created (reporter_user_id, created_at),
  KEY ix_reports_resolver (resolved_by_user_id),
  CONSTRAINT fk_reports_reporter
    FOREIGN KEY (reporter_user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_reports_question
    FOREIGN KEY (question_id) REFERENCES diagnosis_questions (id)
      ON DELETE CASCADE,
  CONSTRAINT fk_reports_resolver
    FOREIGN KEY (resolved_by_user_id) REFERENCES users (id)
      ON DELETE SET NULL,
  CONSTRAINT chk_reports_type
    CHECK (report_type IN ('INCORRECT', 'AMBIGUOUS', 'DUPLICATE', 'OTHER')),
  CONSTRAINT chk_reports_status
    CHECK (report_status IN ('OPEN', 'RESOLVED', 'DISMISSED'))
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE ai_problem_bank_settings (
  id TINYINT UNSIGNED NOT NULL,
  is_enabled TINYINT(1) NOT NULL DEFAULT 0,
  owner_user_id BIGINT UNSIGNED NULL,
  low_water_mark SMALLINT UNSIGNED NOT NULL DEFAULT 20,
  target_count SMALLINT UNSIGNED NOT NULL DEFAULT 30,
  last_run_at DATETIME(6) NULL,
  last_error VARCHAR(500) NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
    ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY ix_problem_bank_owner (owner_user_id),
  CONSTRAINT fk_problem_bank_owner
    FOREIGN KEY (owner_user_id) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT chk_problem_bank_enabled CHECK (is_enabled IN (0, 1)),
  CONSTRAINT chk_problem_bank_levels
    CHECK (
      low_water_mark BETWEEN 5 AND 500
      AND target_count BETWEEN 5 AND 1000
      AND target_count >= low_water_mark
    )
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

CREATE TABLE user_active_plans (
  user_id BIGINT UNSIGNED NOT NULL,
  subject_id BIGINT UNSIGNED NOT NULL,
  plan_id BIGINT UNSIGNED NOT NULL,
  selected_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id, subject_id),
  KEY ix_active_plans_plan (plan_id),
  KEY ix_active_plans_subject (subject_id),
  CONSTRAINT fk_active_plans_user
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_active_plans_subject
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE,
  CONSTRAINT fk_active_plans_plan
    FOREIGN KEY (plan_id) REFERENCES daily_plans (id) ON DELETE CASCADE
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_uca1400_ai_ci;

INSERT INTO ai_problem_bank_settings (
  id,
  is_enabled,
  low_water_mark,
  target_count
)
VALUES (1, 0, 20, 30)
ON DUPLICATE KEY UPDATE id = VALUES(id);
