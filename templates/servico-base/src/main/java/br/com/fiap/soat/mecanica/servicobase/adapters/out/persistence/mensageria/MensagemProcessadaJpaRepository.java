package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.UUID;

public interface MensagemProcessadaJpaRepository extends JpaRepository<MensagemProcessadaEntity, UUID> {

    /** @return 1 se a mensagem e nova, 0 se ja foi processada (ou esta sendo, por outra transacao ja confirmada) */
    @Modifying
    @Query(value = """
            INSERT INTO mensagem_processada (message_id, tipo)
            VALUES (:messageId, :tipo)
            ON CONFLICT DO NOTHING
            """, nativeQuery = true)
    int registrarSeNova(@Param("messageId") UUID messageId, @Param("tipo") String tipo);
}
