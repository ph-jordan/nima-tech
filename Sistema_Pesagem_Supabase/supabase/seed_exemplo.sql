-- =============================================================================
--  SEED DE EXEMPLO (opcional) — rode no SQL Editor do Supabase DEPOIS das migrations.
--  Cria um cenário mínimo: 1 local, 2 armazéns, 3 embalagens, 2 produtos, itens de estoque,
--  especificações (produto × peso × embalagem), regras de tolerância e 2 operadores com cartão.
--  Ajuste nomes/códigos/UIDs para a realidade da planta. Terminais NÃO são criados aqui:
--  use public.admin_terminal_registrar (gera a chave do dispositivo).
-- =============================================================================
begin;

insert into public.locais (codigo, nome) values ('PLANTA1', 'Planta 1 - Beneficiamento');

insert into public.armazens (codigo, nome, local_id, permite_estoque_negativo)
select x.codigo, x.nome, l.id, false
from (values ('MP', 'Materia-prima a granel'), ('PA', 'Produto acabado')) x(codigo, nome)
cross join public.locais l where l.codigo = 'PLANTA1';

insert into public.tipos_embalagem (codigo, nome, nome_exibicao, ordem) values
  ('SACO',   'Saco',   'Saco',   1),
  ('CAIXA',  'Caixa',  'Caixa',  2),
  ('PALETE', 'Palete', 'Palete', 3);

insert into public.produtos (codigo, nome, nome_exibicao, ordem) values
  ('FEIJAO',  'Feijao carioca', 'Feijao',  1),
  ('LARANJA', 'Laranja pera',   'Laranja', 2);

-- itens de estoque: granel (KG) + embalados (UN)
insert into public.itens_estoque (codigo, nome, tipo, unidade, produto_id, tipo_embalagem_id, peso_nominal_kg)
select v.codigo, v.nome, v.tipo::public.item_tipo, v.un::public.unidade_estoque, p.id, te.id, v.peso
from (values
  ('FEIJAO-GRANEL', 'Feijao a granel',       'MATERIA_PRIMA', 'KG', 'FEIJAO',  null,    null::numeric),
  ('FEIJAO-SC10',   'Feijao saco 10 kg',     'PRODUTO_FINAL', 'UN', 'FEIJAO',  'SACO',  10),
  ('FEIJAO-SC20',   'Feijao saco 20 kg',     'PRODUTO_FINAL', 'UN', 'FEIJAO',  'SACO',  20),
  ('FEIJAO-SC30',   'Feijao saco 30 kg',     'PRODUTO_FINAL', 'UN', 'FEIJAO',  'SACO',  30),
  ('FEIJAO-CX20',   'Feijao caixa 20 kg',    'PRODUTO_FINAL', 'UN', 'FEIJAO',  'CAIXA', 20),
  ('LARANJA-GRANEL','Laranja a granel',      'MATERIA_PRIMA', 'KG', 'LARANJA', null,    null),
  ('LARANJA-CX20',  'Laranja caixa 20 kg',   'PRODUTO_FINAL', 'UN', 'LARANJA', 'CAIXA', 20)
) v(codigo, nome, tipo, un, prod, emb, peso)
join public.produtos p on p.codigo = v.prod
left join public.tipos_embalagem te on te.codigo = v.emb;

-- especificações operacionais: produto + peso + embalagem → origem/destino
insert into public.produto_embalagens
  (produto_id, peso_nominal_kg, tipo_embalagem_id, item_origem_id, armazem_origem_id,
   item_destino_id, armazem_destino_id, unidades_por_pesagem, base_consumo)
select p.id, v.peso, te.id, io.id, ao.id, idt.id, ad.id, 1, 'PESO_LIDO'
from (values
  ('FEIJAO',  10, 'SACO',  'FEIJAO-GRANEL',  'FEIJAO-SC10'),
  ('FEIJAO',  20, 'SACO',  'FEIJAO-GRANEL',  'FEIJAO-SC20'),
  ('FEIJAO',  30, 'SACO',  'FEIJAO-GRANEL',  'FEIJAO-SC30'),
  ('FEIJAO',  20, 'CAIXA', 'FEIJAO-GRANEL',  'FEIJAO-CX20'),
  ('LARANJA', 20, 'CAIXA', 'LARANJA-GRANEL', 'LARANJA-CX20')
) v(prod, peso, emb, origem, destino)
join public.produtos p        on p.codigo  = v.prod
join public.tipos_embalagem te on te.codigo = v.emb
join public.itens_estoque io  on io.codigo  = v.origem
join public.itens_estoque idt on idt.codigo = v.destino
join public.armazens ao       on ao.codigo  = 'MP'
join public.armazens ad       on ad.codigo  = 'PA';

-- tolerâncias: global (0 abaixo / +0,200 kg acima — mesma regra do firmware antigo)
insert into public.regras_tolerancia (descricao, modo, tolerancia_inferior, tolerancia_superior)
values ('Padrao global: nunca abaixo do nominal, ate +200 g', 'ABSOLUTA_KG', 0, 0.200);
-- laranja: ±1%
insert into public.regras_tolerancia (descricao, produto_id, modo, tolerancia_inferior, tolerancia_superior)
select 'Laranja: +/- 1%', id, 'PERCENTUAL', 1, 1 from public.produtos where codigo = 'LARANJA';

-- operadores + cartões (UIDs em HEX, como o firmware novo envia)
insert into public.operadores (matricula, nome, nome_exibicao)
values ('0001', 'Joao da Silva', 'Joao Silva'), ('0002', 'Maria Souza', 'Maria Souza');
insert into public.cartoes_rfid (uid, descricao) values ('A1B2C3D4', 'Cartao Joao'), ('11223344', 'Cartao Maria');
insert into public.cartoes_rfid_vinculos (cartao_id, operador_id, motivo)
select c.id, o.id, 'Cadastro inicial'
from (values ('A1B2C3D4', '0001'), ('11223344', '0002')) v(uid, mat)
join public.cartoes_rfid c on c.uid = v.uid
join public.operadores o  on o.matricula = v.mat;

-- saldo inicial de matéria-prima (entrada manual auditada)
select public._estoque_lancar('ENTRADA_MANUAL', 1::smallint, i.id, a.id, 5000, 5000, gen_random_uuid(),
                              null, null, null, null, 'SISTEMA', gen_random_uuid(), 'Saldo inicial (seed)', now())
from public.itens_estoque i, public.armazens a
where i.codigo in ('FEIJAO-GRANEL', 'LARANJA-GRANEL') and a.codigo = 'MP';

commit;
