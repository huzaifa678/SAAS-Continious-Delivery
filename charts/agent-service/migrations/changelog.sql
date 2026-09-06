--liquibase formatted sql
--
-- Full baseline schema for agent-service, derived from the JPA entities
-- (com.project.agent.adapter.out.persistence.*). Column names/types match Hibernate's
-- default snake_case mapping so the app's ddl-auto=validate passes.
--
-- Safe on pre-existing databases: every object uses IF NOT EXISTS, so a changeSet is a
-- no-op where the object already exists and creates it on a fresh database. Liquibase
-- records each changeSet in DATABASECHANGELOG either way — no manual changelog-sync needed.

-- changeset agent-service:001-create-conversations
CREATE TABLE IF NOT EXISTS conversations (
    id         uuid          PRIMARY KEY,
    tenant_id  uuid          NOT NULL,
    user_id    uuid          NOT NULL,
    title      varchar(255),
    status     varchar(32)   NOT NULL,
    created_at timestamptz   NOT NULL,
    updated_at timestamptz   NOT NULL
);

-- changeset agent-service:002-create-messages
CREATE TABLE IF NOT EXISTS messages (
    id                uuid         PRIMARY KEY,
    content           text         NOT NULL,
    role              varchar(16)  NOT NULL,
    prompt_tokens     integer      NOT NULL,
    completion_tokens integer      NOT NULL,
    created_at        timestamptz  NOT NULL,
    conversation_id   uuid,
    position          integer,
    CONSTRAINT fk_messages_conversation
        FOREIGN KEY (conversation_id) REFERENCES conversations (id)
);

-- changeset agent-service:003-create-agent-executions
CREATE TABLE IF NOT EXISTS agent_executions (
    id                   uuid          PRIMARY KEY,
    version              bigint,
    conversation_id      uuid          NOT NULL,
    model_name           varchar(128)  NOT NULL,
    provider_name        varchar(64)   NOT NULL,
    status               varchar(16)   NOT NULL,
    prompt_tokens        integer       NOT NULL,
    completion_tokens    integer       NOT NULL,
    cost_amount          numeric(19,4) NOT NULL,
    cost_currency        varchar(3)    NOT NULL,
    latency_millis       bigint        NOT NULL,
    retrieval_confidence double precision,
    started_at           timestamptz   NOT NULL,
    completed_at         timestamptz
);

-- changeset agent-service:004-create-tool-executions
CREATE TABLE IF NOT EXISTS tool_executions (
    id                  uuid          PRIMARY KEY,
    tool_name           varchar(128)  NOT NULL,
    request             text          NOT NULL,
    response            text,
    status              varchar(16)   NOT NULL,
    latency_millis      bigint        NOT NULL,
    started_at          timestamptz   NOT NULL,
    completed_at        timestamptz,
    agent_execution_id  uuid,
    position            integer,
    CONSTRAINT fk_tool_executions_agent_execution
        FOREIGN KEY (agent_execution_id) REFERENCES agent_executions (id)
);

-- changeset agent-service:005-create-feedback
CREATE TABLE IF NOT EXISTS feedback (
    id              uuid         PRIMARY KEY,
    conversation_id uuid         NOT NULL,
    message_id      uuid         NOT NULL,
    rating          integer      NOT NULL,
    comment         text,
    created_at      timestamptz  NOT NULL,
    updated_at      timestamptz  NOT NULL
);

-- changeset agent-service:006-add-retrieval-confidence
-- Reconciles databases created before retrieval_confidence existed (no-op on fresh DBs,
-- where 003 already created the column). Persists RAG retrieval confidence per execution.
ALTER TABLE agent_executions
    ADD COLUMN IF NOT EXISTS retrieval_confidence double precision;

-- changeset agent-service:007-hybrid-search-fts-index runAlways:true
-- Full-text GIN index backing hybrid RAG sparse retrieval. The conversation_embeddings
-- table is created by langchain4j at app runtime, so this is guarded on its existence and
-- runs on every sync until the table appears (then it is a cheap no-op via IF NOT EXISTS).
DO $$
BEGIN
    IF to_regclass('public.conversation_embeddings') IS NOT NULL THEN
        CREATE INDEX IF NOT EXISTS conversation_embeddings_text_fts_idx
            ON conversation_embeddings
            USING GIN (to_tsvector('english', text));
    END IF;
END $$;
