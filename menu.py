import json
import subprocess
import os
import time
import shutil
from pathlib import Path
from datetime import datetime

# Caminho para o registry.json no mesmo nível do menu.py
BASE_DIR = Path(__file__).parent
REGISTRY_PATH = BASE_DIR / "registry.json"

def ensure_registry(path: Path = REGISTRY_PATH):
    """Garante que o arquivo registry.json exista e tenha estrutura válida."""
    if not path.exists():
        seed = {"paineis": []}
        with path.open("w", encoding="utf-8") as f:
            json.dump(seed, f, ensure_ascii=False, indent=2)
        print("✅ Arquivo registry.json criado automaticamente.")
    else:
        try:
            with path.open("r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict) or "paineis" not in data:
                raise ValueError
        except Exception:
            print("⚠️  registry.json inválido. Recriando arquivo base...")
            seed = {"paineis": []}
            with path.open("w", encoding="utf-8") as f:
                json.dump(seed, f, ensure_ascii=False, indent=2)

ensure_registry()

# =========================
# Config raiz
# =========================
ROOT       = Path(__file__).resolve().parent
PS1        = ROOT / "pbi_refresh.ps1"
RUN_LAUNCH = ROOT / "run_task.ps1"
REGISTRY   = ROOT / "registry.json"
CRED_DIR   = ROOT / ".cred"
CRED       = CRED_DIR / "global_pbi.cred"
LOG_DIR    = ROOT / "logs"

# =========================
# Utilidades de UX
# =========================
def run_schtasks(args: list[str]) -> subprocess.CompletedProcess:
    """Executa o schtasks de forma segura e compatível com encoding PT-BR."""
    return subprocess.run(
        ["schtasks", *args],
        capture_output=True,
        text=True,
        encoding="latin-1",
        errors="ignore"
    )

def clear():
    os.system("cls" if os.name == "nt" else "clear")

def pause(msg="Pressione Enter para continuar..."):
    try:
        input(msg)
    except EOFError:
        pass

def ps_exe():
    # Resolve primeiro powershell clássico; se não existir, tenta pwsh
    candidates = [
        r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
        shutil.which("powershell"),
        shutil.which("pwsh"),
        r"C:\Program Files\PowerShell\7\pwsh.exe",
    ]
    for p in candidates:
        if p and os.path.exists(p):
            return p
    return "powershell"  # fallback

# =========================
# Helpers de nome
# =========================
def _safe_key(name: str) -> str:
    """Slug ASCII estável e sem acentos, usado em nomes de task e TaskKey."""
    import unicodedata
    nfkd = unicodedata.normalize('NFKD', name)
    only_ascii = "".join(c for c in nfkd if not unicodedata.combining(c))
    safe = "".join(ch if ch.isalnum() or ch in ("-", "_") else "_" for ch in only_ascii)
    return safe[:120]

def _safe_task_name(name: str) -> str:
    # Nome padronizado COM prefixo e barra raiz (TaskPath "\").
    # Usar sempre este padrão para criar/excluir.
    return f"\\BI_Refresh_{_safe_key(name)}"[:140]

# =========================
# Persistência
# =========================
def load_registry():
    """
    Lê o registry.json e garante o esquema atual:
      { "paineis": [ {name, workspace_id, dataset_id, created_at, schedule?, last_success?}, ... ] }
    Migra automaticamente 'datasets' -> 'paineis' se necessário.
    """
    data = {}
    if REGISTRY.exists():
        try:
            data = json.loads(REGISTRY.read_text(encoding="utf-8"))
        except Exception:
            data = {}

    # Migração de 'datasets' -> 'paineis'
    if "paineis" not in data:
        if "datasets" in data and isinstance(data["datasets"], list):
            paineis = []
            for d in data["datasets"]:
                if not isinstance(d, dict):
                    continue
                paineis.append({
                    "name": d.get("name"),
                    "workspace_id": d.get("workspace_id"),
                    "dataset_id": d.get("dataset_id"),
                    "created_at": d.get("created_at"),
                    "schedule": d.get("schedule"),
                    "last_success": d.get("last_success"),
                })
            data = {"paineis": paineis}
            save_registry(data)
        else:
            data = {"paineis": []}
            save_registry(data)

    if not isinstance(data.get("paineis"), list):
        data["paineis"] = []
        save_registry(data)

    return data

def save_registry(data):
    REGISTRY.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

def set_schedule_in_registry(painel_name: str, unit: str, every: int):
    """
    unit: 'MINUTE' ou 'HOURLY'
    every: inteiro >= 1
    """
    data = load_registry()
    changed = False
    for p in data["paineis"]:
        if p.get("name") == painel_name:
            p["schedule"] = {"unit": unit, "every": every}
            changed = True
            break
    if changed:
        save_registry(data)

# =========================
# Gate de pré-requisitos
# =========================
def criar_credencial_global():
    clear()
    print("🔐 Criar/atualizar credencial global do Power BI\n")
    CRED_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        ps_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
        f'$cred=Get-Credential -Message "Informe suas credenciais do Power BI"; '
        f'$cred | Export-Clixml "{CRED}"'
    ]
    subprocess.run(cmd, check=False)
    if CRED.exists():
        print(f"✅ Credencial criada/atualizada em: {CRED}")
    else:
        print("❌ Falha ao criar credencial.")
    pause()

def ensure_prereqs():
    while True:
        clear()
        print("✅ Verificação de pré-requisitos\n")

        # PowerShell
        try:
            subprocess.run(
                [ps_exe(), "-NoProfile", "-Command", "$PSVersionTable.PSVersion.Major"],
                check=False, capture_output=True
            )
        except Exception:
            print("❌ PowerShell não encontrado no PATH.")
            pause()
            raise SystemExit(1)

        # Scripts base
        missing = []
        if not PS1.exists():
            missing.append("pbi_refresh.ps1")
        if not RUN_LAUNCH.exists():
            missing.append("run_task.ps1")
        if missing:
            print("❌ Arquivos faltando:", ", ".join(missing))
            print("Coloque-os no mesmo diretório do menu.py e execute novamente.")
            pause()
            raise SystemExit(1)

        # Credencial global
        CRED_DIR.mkdir(parents=True, exist_ok=True)
        if not CRED.exists():
            print("🔒 Nenhuma credencial global encontrada.")
            op = input("Criar agora? [S/N]: ").strip().upper()
            if op == "S":
                criar_credencial_global()
                continue
            print("Sem credencial não é possível prosseguir.")
            pause()
            raise SystemExit(1)

        # Pasta de logs (sempre log)
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        return

# =========================
# Painéis
# =========================
def cadastrar_painel():
    clear()
    print("🧾 Cadastrar painel\n")
    nome = input("Nome do painel: ").strip()
    ws   = input("Workspace ID (GUID): ").strip()
    ds   = input("Dataset ID (GUID): ").strip()

    if not nome or len(ws) != 36 or len(ds) != 36:
        print("❌ Dados inválidos. Verifique nome, WorkspaceId e DatasetId (GUID).")
        pause(); return

    data = load_registry()
    # de-dup por nome
    data["paineis"] = [p for p in data["paineis"] if p.get("name") != nome]
    data["paineis"].append({
        "name": nome,
        "workspace_id": ws,
        "dataset_id": ds,
        "created_at": datetime.now().isoformat(timespec="seconds")
    })
    save_registry(data)
    print(f"✅ Painel '{nome}' cadastrado.")
    pause()

def listar_paineis(show_pause=True):
    clear()
    data = load_registry()
    paineis = data.get("paineis", [])
    if not paineis:
        print("📭 Nenhum painel cadastrado.")
        if show_pause: pause()
        return []
    print("📚 Painéis cadastrados:\n")
    for i, p in enumerate(paineis, 1):
        sched = p.get("schedule")
        cad = ""
        if sched:
            unit = "min" if sched.get("unit") == "MINUTE" else "h"
            cad = f" ⏱️  cada {sched.get('every')} {unit}"
        last_ok = p.get("last_success")
        ok_str = f" • ✅ last: {last_ok}" if last_ok else ""
        print(f"{i:02d} • {p['name']}  [{p['workspace_id'][:8]}...{p['dataset_id'][:8]}]{cad}{ok_str}")
    if show_pause:
        print(); pause()
    return paineis

def remover_painel():
    clear()
    print("🗑️  Remover painel registrado\n")

    data = load_registry()
    paineis = data.get("paineis", [])
    if not paineis:
        print("Nenhum painel cadastrado.\n")
        pause()
        return

    for i, p in enumerate(paineis, start=1):
        nome = p.get("name")
        print(f"{i}) {nome}")
    print()

    try:
        escolha = int(input("Selecione o número do painel para remover: "))
        if escolha < 1 or escolha > len(paineis):
            raise ValueError
    except ValueError:
        print("❌ Opção inválida.\n")
        pause()
        return

    painel = paineis.pop(escolha - 1)
    save_registry(data)

    # Nome padronizado atual e fallbacks para tarefas antigas
    task_name_std    = _safe_task_name(painel['name'])            # \BI_Refresh_Analise_PK
    task_name_noroot = task_name_std.lstrip("\\")                  # BI_Refresh_Analise_PK
    legacy_raw       = "".join(ch if (str(ch).isalnum() or ch in ('-', '_')) else '_' for ch in painel['name'])
    task_name_legacy = f"BI_Refresh_{legacy_raw}"[:140]            # legacy com acentos preservados

    deleted = False
    for tn in (task_name_std, task_name_noroot, task_name_legacy):
        r = run_schtasks(["/delete", "/tn", tn, "/f"])
        if r.returncode == 0:
            print(f"🧹 Task '{tn}' removida com sucesso.")
            deleted = True
            break
    if not deleted:
        print("⚠️  Nenhuma task correspondente foi removida (nome não encontrado).")

    print(f"✅ Painel '{painel['name']}' removido com sucesso.\n")
    pause()

# =========================
# Execução (sempre com log diário)
# =========================
def executar_refresh():
    paineis = listar_paineis(show_pause=False)
    if not paineis:
        pause()
        return

    print()
    try:
        idx = int(input("Selecione o índice para executar: ").strip())
    except ValueError:
        print("Índice inválido.")
        pause()
        return

    if not (1 <= idx <= len(paineis)):
        print("Índice fora do intervalo.")
        pause()
        return

    p = paineis[idx - 1]

    args = [
        ps_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(PS1),
        "-WorkspaceId", p["workspace_id"],
        "-DatasetId", p["dataset_id"],
        "-CredPath", str(CRED),
        "-Name", p["name"],
        "-LogPath", str(LOG_DIR.resolve())  # SEMPRE log diário (PS1 trata)
    ]

    clear()
    print(f"▶️ Executando refresh para: {p['name']}\n")

    subprocess.run(args, check=False, text=True, encoding="utf-8", errors="ignore")

    print()
    pause()

# =========================
# Agendamento (Minutos/Horas) via run_task.ps1
# =========================
def _schtasks_create(task_name: str, trigger_sc: str, mo: int, painel_name: str) -> bool:
    exe = ps_exe()
    task_key = _safe_key(painel_name)  # ASCII seguro (evita mojibake no /TR)
    tr_cmd = f'"{exe}" -NoProfile -ExecutionPolicy Bypass -File "{RUN_LAUNCH}" -TaskKey "{task_key}"'
    st = time.strftime("%H:%M")
    r = run_schtasks([
        "/Create",
        "/TN", task_name,
        "/TR", tr_cmd,
        "/SC", trigger_sc,
        "/MO", str(mo),
        "/ST", st,
        "/F",
        "/RL", "LIMITED",
        "/RU", os.environ.get("USERNAME", ""),
        "/IT"
    ])
    clear()
    if r.returncode == 0:
        unidade = "minuto(s)" if trigger_sc == "MINUTE" else "hora(s)"
        print(f"✅ Tarefa criada: {task_name} (a cada {mo} {unidade})\n")
        return True
    else:
        print("❌ Falha ao criar tarefa")
        print(r.stdout or ""); print(r.stderr or ""); print()
        return False

def agendar_minutos_ou_horas():
    paineis = listar_paineis(show_pause=False)
    if not paineis:
        pause(); return
    print()
    try:
        idx = int(input("Selecione o índice do painel para agendar: ").strip())
    except ValueError:
        print("Índice inválido."); pause(); return
    if not (1 <= idx <= len(paineis)):
        print("Índice fora do intervalo."); pause(); return
    p = paineis[idx - 1]

    clear()
    print("🗓️  Agendar execução (apenas MINUTOS ou HORAS)\n")
    print("1) A cada N minutos")
    print("2) De N em N horas")
    opt = input("\nSelecione: ").strip()
    if opt not in {"1", "2"}:
        print("Opção inválida."); pause(); return

    try:
        n = int(input("De quanto em quanto tempo deseja atualizar o painel? ").strip())
    except ValueError:
        print("Número inválido."); pause(); return
    if n < 1:
        print("N deve ser >= 1."); pause(); return

    task_name = _safe_task_name(p["name"])  # inclui "\" no início
    if opt == "1":
        ok = _schtasks_create(task_name, "MINUTE", n, p["name"])
        if ok:
            set_schedule_in_registry(p["name"], "MINUTE", n)
    else:
        ok = _schtasks_create(task_name, "HOURLY", n, p["name"])
        if ok:
            set_schedule_in_registry(p["name"], "HOURLY", n)

    pause("Enter para voltar...")

# =========================
# Menu
# =========================
def menu():
    while True:
        clear()
        print("📊  Atualização de Painéis Power BI")
        print()
        print("1) Cadastrar painel")
        print("2) Listar painéis")
        print("3) Executar refresh (sempre com log)")
        print("4) Remover painel")
        print("5) Agendar (Minutos/Horas)")
        print("0) Sair")
        op = input("\nEscolha: ").strip()

        if op == "1":
            cadastrar_painel()
        elif op == "2":
            listar_paineis()
        elif op == "3":
            executar_refresh()
        elif op == "4":
            remover_painel()
        elif op == "5":
            agendar_minutos_ou_horas()
        elif op == "22":
            criar_credencial_global()
        elif op == "0":
            clear(); break
        else:
            print("❌ Opção inválida."); time.sleep(1)

# =========================
# Bootstrap
# =========================
if __name__ == "__main__":
    ensure_prereqs()
    menu()