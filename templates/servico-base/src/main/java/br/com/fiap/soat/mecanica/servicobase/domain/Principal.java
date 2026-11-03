package br.com.fiap.soat.mecanica.servicobase.domain;

import br.com.fiap.soat.mecanica.servicobase.domain.enums.StatusRecursoEnum;
import lombok.Getter;

@Getter
public abstract class Principal {

    protected StatusRecursoEnum status = StatusRecursoEnum.ATIVO;

    public void inativar() {
        this.status = StatusRecursoEnum.INATIVO;
    }

    public void ativar() {
        this.status = StatusRecursoEnum.ATIVO;
    }

    public boolean isAtivo() {
        return status == StatusRecursoEnum.ATIVO;
    }

    public boolean isInativo() {
        return status == StatusRecursoEnum.INATIVO;
    }
}

