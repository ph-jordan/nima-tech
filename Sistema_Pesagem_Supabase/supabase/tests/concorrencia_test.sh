#!/bin/bash
# =============================================================================
#  TESTE DE CONCORRÊNCIA REAL (cenários 17, 18 e 22 com conexões simultâneas)
#  - 2 terminais pesando ao mesmo tempo sobre o MESMO estoque de origem
#  - 1 mesmo evento disparado 15x em paralelo (retry agressivo da placa)
#  Uso: PSQL="psql -h HOST -p PORT -U USER -d BANCO" ./concorrencia_test.sh
#  Pré-requisito: migrations + seed_exemplo.sql + pesagem_tests.sql (cria os terminais de teste).
# =============================================================================
set -euo pipefail
PSQL=${PSQL:-"psql -h /tmp -p 5433 -U postgres -d pesagem_test"}
Q="$PSQL -v ON_ERROR_STOP=1 -qtAX"
N=${N:-40}

$Q <<'SQL'
insert into public.operadores (matricula, nome, nome_exibicao) values ('0101','Conc A','Conc A'),('0102','Conc B','Conc B')
  on conflict (matricula) do nothing;
insert into public.cartoes_rfid (uid) values ('CC000001'),('CC000002') on conflict (uid) do nothing;
insert into public.cartoes_rfid_vinculos (cartao_id, operador_id)
select c.id, o.id from (values ('CC000001','0101'),('CC000002','0102')) v(uid,mat)
join public.cartoes_rfid c on c.uid = v.uid join public.operadores o on o.matricula = v.mat
where not exists (select 1 from public.cartoes_rfid_vinculos x where x.cartao_id = c.id and x.fim is null);
SQL

abrir() { # $1 device $2 key $3 uid  → imprime sessao_id
  $Q <<SQL
select set_config('request.headers', json_build_object('x-device-id','$1','x-device-key','$2')::text, false) \gset
select teste.abrir_sessao('$3', 'FEIJAO', 20, 'SACO');
SQL
}
S1=$(abrir AABBCC001122 chave-t1 CC000001 | tail -1)
S2=$(abrir AABBCC003344 chave-t2 CC000002 | tail -1)
echo "Sessao T1=$S1  T2=$S2"

SALDO0=$($Q -c "select teste.saldo('FEIJAO-GRANEL','MP')")
PA0=$($Q -c "select teste.saldo('FEIJAO-SC20','PA')")

pesar() { # $1 device $2 key $3 sessao $4 peso $5 event_id
  $Q >/dev/null <<SQL
select set_config('request.headers', json_build_object('x-device-id','$1','x-device-key','$2')::text, false);
select public.terminal_evento('CONFIRMAR_PESAGEM', '$5'::uuid,
       jsonb_build_object('sessao_id','$3','peso_lido',$4));
SQL
}

DUP=$(cat /proc/sys/kernel/random/uuid)
pids=()
for i in $(seq 1 $N); do
  peso=$(printf "20.%03d" $(( (i * 7) % 250 )))       # alguns dentro (<=20.200), alguns fora
  if (( i % 2 )); then pesar AABBCC001122 chave-t1 "$S1" "$peso" "$(cat /proc/sys/kernel/random/uuid)" &
  else                pesar AABBCC003344 chave-t2 "$S2" "$peso" "$(cat /proc/sys/kernel/random/uuid)" & fi
  pids+=($!)
done
for i in $(seq 1 15); do pesar AABBCC001122 chave-t1 "$S1" 20.111 "$DUP" & pids+=($!); done
fail=0; for p in "${pids[@]}"; do wait "$p" || fail=$((fail+1)); done
echo "Chamadas com erro HTTP/SQL (seriam reenviadas pela placa): $fail"

$Q <<SQL
do \$\$
declare v_conf numeric; v_kg numeric; v_n int;
begin
  select count(*), coalesce(sum(peso_lido_kg),0) into v_n, v_kg
    from public.pesagens where sessao_id in ('$S1','$S2') and contabilizada;
  perform teste.ok(teste.saldo('FEIJAO-GRANEL','MP') = $SALDO0 - v_kg,
                   'C1 saldo origem = inicial - soma exata das pesagens válidas (' || v_n || ' válidas, ' || v_kg || ' kg)');
  perform teste.ok(teste.saldo('FEIJAO-SC20','PA') = $PA0 + v_n, 'C2 produto final = +1 por pesagem válida');
  perform teste.ok((select count(*) from public.estoque_movimentos where sessao_id in ('$S1','$S2')) = 2 * v_n,
                   'C3 exatamente 2 movimentos por pesagem válida');
  perform teste.ok((select count(*) from public.pesagens where event_id = '$DUP') = 1,
                   'C4 mesmo evento enviado 15x em paralelo → 1 pesagem');
  perform teste.ok((select count(*) from public.pesagens where sessao_id in ('$S1','$S2')) = $N + 1,
                   'C5 total de pesagens = $N + 1');
  perform teste.ok(not exists (select sessao_id from public.pesagens where sessao_id in ('$S1','$S2')
                               group by sessao_id having count(*) <> max(sequencia)),
                   'C6 sequência sem buracos nem repetição em cada sessão');
  perform teste.ok((select sum(quantidade) from public.estoque_movimentos m
                     where m.item_id = (select id from public.itens_estoque where codigo='FEIJAO-GRANEL')
                       and m.armazem_id = (select id from public.armazens where codigo='MP')
                       and m.sentido = 1)
                   - (select sum(quantidade) from public.estoque_movimentos m
                     where m.item_id = (select id from public.itens_estoque where codigo='FEIJAO-GRANEL')
                       and m.armazem_id = (select id from public.armazens where codigo='MP')
                       and m.sentido = -1) = teste.saldo('FEIJAO-GRANEL','MP'),
                   'C7 saldo = soma do razão (ledger) — sem divergência');
end \$\$;
SQL
for d in "AABBCC001122 chave-t1 $S1" "AABBCC003344 chave-t2 $S2"; do
  set -- $d
  $Q >/dev/null <<SQL
select set_config('request.headers', json_build_object('x-device-id','$1','x-device-key','$2')::text, false);
select public.terminal_evento('FINALIZAR_SESSAO', gen_random_uuid(), jsonb_build_object('sessao_id','$3'));
SQL
done
echo "CONCORRENCIA OK"
