package br.com.fiap.soat.mecanica.servicobase.domain.enums;

public enum StatusRecursoEnum {

    ATIVO("Ativo"),
    INATIVO("Inativo");

    private final String descricao;

    StatusRecursoEnum(String descricao) {
        this.descricao = descricao;
    }

    @Override
    public String toString() {
        return descricao;
    }
}
