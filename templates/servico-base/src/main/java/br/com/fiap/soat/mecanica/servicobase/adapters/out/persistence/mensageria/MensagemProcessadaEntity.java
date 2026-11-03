package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "mensagem_processada")
public class MensagemProcessadaEntity {

    @Id
    @Column(name = "message_id")
    private UUID messageId;

    @Column(nullable = false, length = 100)
    private String tipo;

    @Column(name = "processada_em", nullable = false)
    private Instant processadaEm;
}
