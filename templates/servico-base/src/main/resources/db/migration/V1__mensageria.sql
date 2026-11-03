-- Mensageria do esqueleto (outbox e idempotencia do consumidor). As migrations de dominio comecam em V2.

CREATE TABLE outbox (
    id            UUID PRIMARY KEY,
    message_id    UUID         NOT NULL UNIQUE,
    destino       VARCHAR(100) NOT NULL,
    tipo          VARCHAR(100) NOT NULL,
    envelope      JSONB        NOT NULL,
    criado_em     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    publicado_em  TIMESTAMPTZ,
    tentativas    INT          NOT NULL DEFAULT 0,
    ultimo_erro   TEXT
);
CREATE INDEX ix_outbox_pendentes ON outbox (criado_em) WHERE publicado_em IS NULL;

CREATE TABLE mensagem_processada (
    message_id    UUID PRIMARY KEY,
    tipo          VARCHAR(100) NOT NULL,
    processada_em TIMESTAMPTZ  NOT NULL DEFAULT now()
);
