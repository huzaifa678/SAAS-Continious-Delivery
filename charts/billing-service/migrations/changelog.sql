--liquibase formatted sql
--
-- Full baseline schema for billing-service, derived from the JPA entities
-- (com.project.billing.adapter.out.persistence.*). Column names/types match Hibernate's
-- mapping (explicit @Column names on invoices; default snake_case on usage_charges) so
-- the app's ddl-auto=validate passes.
--
-- Safe on pre-existing databases: every object uses IF NOT EXISTS. Add new schema changes
-- as further changeSets below (never edit an already-applied changeSet — its checksum is
-- recorded in DATABASECHANGELOG).

-- changeset billing-service:001-create-invoices
CREATE TABLE IF NOT EXISTS invoices (
    invoice_id      uuid          NOT NULL PRIMARY KEY,
    subscription_id uuid          NOT NULL,
    customer_id     uuid          NOT NULL,
    amount          numeric(19,4) NOT NULL,
    currency        varchar(3)    NOT NULL,
    status          varchar(32)   NOT NULL,
    issued_at       timestamptz   NOT NULL,
    due_at          timestamptz   NOT NULL
);

-- changeset billing-service:002-create-usage-charges
CREATE TABLE IF NOT EXISTS usage_charges (
    id          uuid          PRIMARY KEY,
    invoice_id  uuid          NOT NULL,
    metric      varchar(255)  NOT NULL,
    quantity    bigint        NOT NULL,
    unit_price  numeric(38,2) NOT NULL,
    total_price numeric(38,2) NOT NULL,
    CONSTRAINT fk_usage_charges_invoice
        FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id)
);
