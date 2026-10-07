#!/usr/bin/env python3
"""
SIMULADOR DO TERMINAL (ESP32) — teste ponta a ponta da API no Supabase, sem a placa.

Faz exatamente as mesmas chamadas HTTP do firmware v4 (mesmos cabeçalhos e o mesmo
formato de corpo), percorrendo o fluxo completo:
  heartbeat → catálogo → RFID → confirmar operador → produto → peso → embalagem →
  iniciar → (cancelar bloqueado) → pesagens dentro/fora → resposta perdida + reenvio
  pela fila offline (replay) → finalizar.

Uso (Supabase real):
  python3 simulador_terminal.py --url https://<ref>.supabase.co --apikey <publishable/anon> \
      --device AABBCC001122 --key <chave do terminal> --uid A1B2C3D4
Uso (PostgREST local, sem /rest/v1):
  python3 simulador_terminal.py --url http://localhost:3001 --sem-rest-v1 --apikey x ...
Só usa a biblioteca padrão do Python.
"""
import argparse, json, sys, uuid, urllib.request, urllib.error, datetime

p = argparse.ArgumentParser()
p.add_argument("--url", required=True)
p.add_argument("--apikey", required=True)
p.add_argument("--device", required=True)
p.add_argument("--key", required=True)
p.add_argument("--uid", required=True, help="UID do cartão RFID em HEX")
p.add_argument("--produto", help="nome do produto no catálogo (padrão: o primeiro)")
p.add_argument("--sem-rest-v1", action="store_true", help="PostgREST local (sem o prefixo /rest/v1)")
a = p.parse_args()

BASE = a.url.rstrip("/") + ("" if a.sem_rest_v1 else "/rest/v1") + "/rpc/"


def rpc(fn, body_text):
    headers = {"Content-Type": "application/json", "apikey": a.apikey,
               "x-device-id": a.device, "x-device-key": a.key}
    if a.apikey.startswith("eyJ"):
        headers["Authorization"] = "Bearer " + a.apikey
    req = urllib.request.Request(BASE + fn, data=body_text.encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def agora():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def evento(tipo, dados):
    # igual ao firmware: o texto de "dados" é gerado UMA vez e reutilizado online e na fila
    return {"tipo": tipo, "id": str(uuid.uuid4()), "dados": json.dumps(dados, separators=(",", ":"))}


def online(e):
    return rpc("terminal_evento", '{"p_tipo":"%s","p_event_id":"%s","p_dados":%s}' % (e["tipo"], e["id"], e["dados"]))


def linha_fila(e):
    return '{"tipo":"%s","event_id":"%s","dados":%s}' % (e["tipo"], e["id"], e["dados"])


falhas = 0
def check(cond, msg):
    global falhas
    print(("OK   " if cond else "FALHA") + "  " + msg)
    if not cond:
        falhas += 1


code, r = rpc("terminal_heartbeat", '{"p_dados":{"firmware_versao":"simulador","estado":"AGUARDANDO_RFID","eventos_pendentes":0}}')
check(code == 200 and r["ok"], f"heartbeat HTTP {code} terminal={r.get('terminal', {}).get('nome') if isinstance(r, dict) else r}")
if code != 200:
    sys.exit(f"Sem autenticação do terminal: {r}")
if r.get("sessao_aberta"):
    s = r["sessao_aberta"]
    print(f"Sessão aberta encontrada ({s['status']}). Finalizando para começar limpo...")
    tipo = "FINALIZAR_SESSAO" if s["status"] == "PESAGEM_EM_ANDAMENTO" else "CANCELAR_SESSAO"
    online(evento(tipo, {"sessao_id": s["sessao_id"], "ocorrido_em": agora()}))

code, r = rpc("terminal_catalogo", "{}")
check(code == 200 and len(r["produtos"]) > 0, f"catálogo: {[x['nome'] for x in r['produtos']]}")

code, r = online(evento("IDENTIFICAR_CARTAO", {"uid": "FFFFFFFF", "ocorrido_em": agora()}))
check(code == 200 and r["codigo"] == "RFID_INVALIDO", "cartão desconhecido recusado")

code, r = online(evento("IDENTIFICAR_CARTAO", {"uid": a.uid, "ocorrido_em": agora()}))
check(code == 200 and r["ok"], f"RFID {a.uid} → {r.get('codigo')} {r.get('mensagem')}")
if not r.get("ok"):
    sys.exit(json.dumps(r, indent=2, ensure_ascii=False))
sid = r["sessao_id"]
cat = r["catalogo"]
prod = next((x for x in cat if a.produto is None or x["nome"].lower() == a.produto.lower()), cat[0])
peso = prod["pesos"][0]
emb = peso["embalagens"][0]

for tipo, dados in [("CONFIRMAR_OPERADOR", {"sessao_id": sid, "confirmado": True}),
                    ("SELECIONAR_PRODUTO", {"sessao_id": sid, "produto_id": prod["id"]}),
                    ("SELECIONAR_PESO", {"sessao_id": sid, "peso_nominal_kg": peso["peso_kg"]}),
                    ("SELECIONAR_EMBALAGEM", {"sessao_id": sid, "tipo_embalagem_id": emb["id"]}),
                    ("INICIAR_PESAGEM", {"sessao_id": sid})]:
    dados["ocorrido_em"] = agora()
    code, r = online(evento(tipo, dados))
    check(code == 200 and r["ok"], f"{tipo} → {r.get('codigo')}")
tol = r["sessao"]["tolerancia"]
mn, mx = float(tol["limite_min_kg"]), float(tol["limite_max_kg"])
print(f"   {prod['nome']} {peso['peso_kg']} kg {emb['nome']} — tolerância congelada {mn:.3f}–{mx:.3f} kg")

code, r = online(evento("CANCELAR_SESSAO", {"sessao_id": sid, "ocorrido_em": agora()}))
check(r["codigo"] == "CANCELAMENTO_BLOQUEADO", "CANCELAR depois de iniciar → bloqueado")

def pesar(valor, seq):
    return evento("CONFIRMAR_PESAGEM", {"sessao_id": sid, "peso_lido": round(valor, 3), "unidade": "kg",
                                        "lido_em": agora(), "confirmado_em": agora(),
                                        "sequencia_terminal": seq, "leitura_estavel": True})

code, r = online(pesar((mn + mx) / 2, 1))
check(r["codigo"] == "PESAGEM_CONFIRMADA", f"pesagem {(mn + mx) / 2:.3f} → {r['codigo']} estoque={bool(r.get('estoque'))}")
code, r = online(pesar(mn - 0.5, 2))
check(r["codigo"] == "FORA_TOLERANCIA", f"pesagem {mn - 0.5:.3f} → {r['codigo']}")

# Resposta perdida: a placa enviou online, não recebeu resposta e o evento ficou na fila do SD.
e = pesar(mx, 3)
code, r1 = online(e)
code, r2 = rpc("terminal_sincronizar", '{"p_eventos":[%s]}' % linha_fila(e))
res = r2["resultados"][0]
check(res["replay"] is True and res["pesagem_id"] == r1["pesagem_id"], "reenvio pela fila = replay (não duplica)")

# Lote offline em ordem + finalização
lote = [pesar(mn, 4), pesar(mx + 1, 5), evento("FINALIZAR_SESSAO", {"sessao_id": sid, "ocorrido_em": agora()})]
code, r = rpc("terminal_sincronizar", '{"p_eventos":[%s]}' % ",".join(linha_fila(x) for x in lote))
check(code == 200 and all(not x["retry"] for x in r["resultados"]), f"sync offline: {[x['codigo'] for x in r['resultados']]}")
t = r["resultados"][-1]["sessao"]["totais"]
check(t["validas"] == 3 and t["fora_tolerancia"] == 2, f"totais finais: {t}")

print("\nRESULTADO:", "TUDO OK" if falhas == 0 else f"{falhas} FALHA(S)")
sys.exit(1 if falhas else 0)
