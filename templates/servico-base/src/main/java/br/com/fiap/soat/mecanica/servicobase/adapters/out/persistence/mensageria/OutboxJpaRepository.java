package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface OutboxJpaRepository extends JpaRepository<OutboxEntity, UUID> {

    /**
     * Pendentes mais antigos, travados ate o fim da transacao. O SKIP LOCKED faz cada replica pegar
     * um lote diferente, sem publicar a mesma linha duas vezes.
     */
    @Query(value = """
            SELECT * FROM outbox
            WHERE publicado_em IS NULL
            ORDER BY criado_em
            LIMIT :limite
            FOR UPDATE SKIP LOCKED
            """, nativeQuery = true)
    List<OutboxEntity> travarPendentes(@Param("limite") int limite);

    boolean existsByMessageId(UUID messageId);
}
