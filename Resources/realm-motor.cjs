// Motor do visualizador de Realm do Build Remoto.
// Usa o pacote "realm" do próprio projeto (mesma versão do app => mesmo formato de arquivo).
// Protocolo: uma requisição JSON por linha no stdin, uma resposta JSON por linha no stdout.
"use strict";
const Realm = require(process.argv[2]);
const { BSON } = Realm;
const fs = require("fs");
const readline = require("readline");

let realm = null;
let caminho = null;

const LIMITE_LISTA = 200;
const LIMITE_TEXTO_CELULA = 300;

// ---------- schema ----------

function schemaDe(r) {
  return r.schema.map((s) => ({
    name: s.name,
    primaryKey: s.primaryKey || null,
    embedded: !!s.embedded,
    asymmetric: !!s.asymmetric,
    properties: Object.values(s.properties).map((p) => ({
      name: p.name,
      type: p.type,
      objectType: p.objectType || null,
      optional: !!p.optional,
      indexed: !!p.indexed,
      property: p.property || null,
      mapTo: p.mapTo || p.name,
    })),
  }));
}

function info() {
  const classes = schemaDe(realm);
  const contagens = {};
  for (const c of classes) {
    try { contagens[c.name] = c.embedded ? null : realm.objects(c.name).length; } catch { contagens[c.name] = null; }
  }
  let tamanho = 0;
  try { tamanho = fs.statSync(caminho).size; } catch {}
  return { schemaVersion: realm.schemaVersion, classes, contagens, tamanho, caminho };
}

// ---------- valores ----------

function chave(o) { try { return String(o._objectKey()); } catch { return null; } }

function rotulo(o) {
  if (!o) return null;
  const s = o.objectSchema();
  if (s.primaryKey) return String(o[s.primaryKey]);
  for (const k of ["name", "nome", "title", "titulo", "descricao", "description", "id", "_id", "codigo"]) {
    if (k in s.properties && o[k] != null) return String(o[k]);
  }
  return "#" + chave(o);
}

function simples(v, curto) {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) return { $date: isNaN(v) ? null : v.toISOString() };
  if (v instanceof BSON.ObjectId) return { $oid: v.toHexString() };
  if (v instanceof BSON.UUID) return { $uuid: v.toHexString(true) };
  if (v instanceof BSON.Decimal128) return { $decimal: v.toString() };
  if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) {
    const b = Buffer.from(v instanceof ArrayBuffer ? v : v.buffer);
    return { $bin: b.length, preview: b.subarray(0, 48).toString("hex") };
  }
  if (v instanceof Realm.Object) {
    const s = v.objectSchema();
    if (s.embedded) return curto ? { $embedded: s.name } : { $embedded: s.name, valores: objetoParaJSON(v, true) };
    return { $link: s.name, key: chave(v), label: rotulo(v) };
  }
  if (v instanceof Realm.List || v instanceof Realm.Set || v instanceof Realm.Results || Array.isArray(v)) {
    const arr = [...v];
    return { $list: arr.length, itens: arr.slice(0, curto ? 5 : LIMITE_LISTA).map((x) => simples(x, true)) };
  }
  if (v instanceof Realm.Dictionary || (typeof v === "object" && v.constructor === Object)) {
    const o = {};
    for (const k of Object.keys(v)) o[k] = simples(v[k], true);
    return { $dict: Object.keys(v).length, valores: o };
  }
  if (typeof v === "string" && curto && v.length > LIMITE_TEXTO_CELULA) return v.slice(0, LIMITE_TEXTO_CELULA) + "…";
  if (typeof v === "bigint") return Number(v);
  if (typeof v === "number" && !isFinite(v)) return { $num: String(v) };
  return v;
}

function objetoParaJSON(o, curto) {
  const s = o.objectSchema();
  const valores = {};
  for (const p of Object.keys(s.properties)) {
    if (s.properties[p].type === "linkingObjects") {
      try { valores[p] = { $list: o[p].length, itens: [...o[p]].slice(0, curto ? 5 : LIMITE_LISTA).map((x) => simples(x, true)) }; } catch { valores[p] = null; }
      continue;
    }
    valores[p] = simples(o[p], curto);
  }
  return valores;
}

// ---------- conversão do que vem do app para o tipo do Realm ----------

const PRIMITIVOS = new Set(["string", "int", "float", "double", "bool", "date", "objectId", "uuid", "decimal128", "data", "mixed"]);

function converter(p, v) {
  if (v === null || v === undefined) {
    if (!p.optional && !["list", "set", "dictionary"].includes(p.type)) throw new Error(`${p.name} não aceita nulo`);
    return null;
  }
  const elemento = () => PRIMITIVOS.has(p.objectType)
    ? { ...p, type: p.objectType, optional: true }
    : { ...p, type: "object", objectType: p.objectType, optional: true };
  if (p.type === "list" || p.type === "set") {
    if (!Array.isArray(v)) throw new Error(`${p.name}: esperado uma lista JSON, ex.: [1, 2]`);
    return v.map((x) => converter(elemento(), x));
  }
  if (p.type === "dictionary") {
    if (typeof v !== "object" || Array.isArray(v)) throw new Error(`${p.name}: esperado um objeto JSON, ex.: {"a": 1}`);
    const o = {};
    for (const k of Object.keys(v)) o[k] = converter(elemento(), v[k]);
    return o;
  }
  switch (p.type) {
    case "string": return String(v);
    case "int": { const n = Number(v); if (!Number.isInteger(n)) throw new Error(`${p.name}: "${v}" não é inteiro`); return n; }
    case "float": case "double": { const n = Number(v); if (isNaN(n)) throw new Error(`${p.name}: "${v}" não é número`); return n; }
    case "bool": return v === true || v === "true" || v === 1 || v === "1";
    case "date": { const d = new Date(v.$date || v); if (isNaN(d)) throw new Error(`${p.name}: data inválida`); return d; }
    case "objectId": return new BSON.ObjectId(v.$oid || v);
    case "uuid": return new BSON.UUID(v.$uuid || v);
    case "decimal128": return BSON.Decimal128.fromString(String(v.$decimal || v));
    case "data": return Buffer.from(String(v.$hex || v), "hex");
    case "mixed": return typeof v === "string" ? v : v;
    case "object": {
      if (v.$key !== undefined) return realm._objectForObjectKey(p.objectType, String(v.$key));
      const destino = realm.schema.find((s) => s.name === p.objectType);
      if (destino && destino.embedded) return v;
      const pk = destino && destino.primaryKey;
      if (!pk) throw new Error(`${p.objectType} não tem chave primária: escolha o registro pela lista`);
      const tipoPk = destino.properties[pk].type;
      const valorPk = converter({ name: pk, type: tipoPk, optional: false }, v.$pk !== undefined ? v.$pk : v);
      const alvo = realm.objectForPrimaryKey(p.objectType, valorPk);
      if (!alvo) throw new Error(`Nenhum ${p.objectType} com ${pk} = ${valorPk}`);
      return alvo;
    }
    default: return v;
  }
}

function objeto(cls, key) {
  const o = realm._objectForObjectKey(cls, String(key));
  if (!o || !o.isValid()) throw new Error(`Registro não encontrado (${cls} #${key}) — pode ter sido apagado`);
  return o;
}

function propDe(cls, nome) {
  const s = realm.schema.find((x) => x.name === cls);
  if (!s) throw new Error(`Classe ${cls} não existe`);
  const p = s.properties[nome];
  if (!p) throw new Error(`${cls} não tem o campo ${nome}`);
  return p;
}

/// Valor escrito como literal de RQL (para montar filtros prontos)
function literal(v) {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "number" || typeof v === "bigint") return String(v);
  if (typeof v === "boolean") return String(v);
  if (v instanceof BSON.ObjectId) return `oid(${v.toHexString()})`;
  if (v instanceof BSON.UUID) return `uuid(${v.toHexString(true)})`;
  if (v instanceof Date) return `T${Math.floor(v.getTime() / 1000)}:0`;
  return JSON.stringify(String(v));
}

// ---------- comandos ----------

function resultados(q) {
  let r = realm.objects(q.cls);
  if (q.filtro && q.filtro.trim()) r = r.filtered(q.filtro);
  if (q.ordem) r = r.sorted(q.ordem, !!q.desc);
  return r;
}

const comandos = {
  abrir(q) {
    if (realm) { realm.close(); realm = null; }
    caminho = q.path;
    const versao = Realm.schemaVersion(caminho);
    realm = new Realm({ path: caminho, schemaVersion: versao < 0 ? 0 : versao });
    return info();
  },
  info() { return info(); },
  consultar(q) {
    const r = resultados(q);
    const total = r.length;
    const ini = Math.max(0, q.offset || 0);
    const fim = Math.min(total, ini + (q.limite || 200));
    const linhas = [];
    for (let i = ini; i < fim; i++) {
      const o = r[i];
      linhas.push({ key: chave(o), valores: objetoParaJSON(o, true) });
    }
    return { total, linhas };
  },
  objeto(q) {
    const o = objeto(q.cls, q.key);
    // quem aponta para este registro (links e listas de outras classes)
    const apontam = [];
    for (const s of realm.schema) {
      if (s.embedded) continue;
      for (const p of Object.values(s.properties)) {
        if (p.objectType !== q.cls || p.type === "linkingObjects") continue;
        const filtro = p.type === "object" ? `${p.name} == $0` : p.type === "list" || p.type === "set" ? `ANY ${p.name} == $0` : null;
        if (!filtro) continue;
        try {
          const r = realm.objects(s.name).filtered(filtro, o);
          const pk = realm.schema.find((x) => x.name === q.cls).primaryKey;
          const lit = pk ? literal(o[pk]) : null;
          const rql = lit === null ? "" : p.type === "object" ? `${p.name}.${pk} == ${lit}` : `ANY ${p.name}.${pk} == ${lit}`;
          if (r.length) apontam.push({ cls: s.name, campo: p.name, total: r.length, filtro: rql,
                                       itens: [...r].slice(0, 30).map((x) => ({ key: chave(x), label: rotulo(x) })) });
        } catch {}
      }
    }
    return { key: chave(o), label: rotulo(o), valores: objetoParaJSON(o, false), apontam };
  },
  atualizar(q) {
    const o = objeto(q.cls, q.key);
    realm.write(() => {
      for (const [campo, valor] of Object.entries(q.valores)) {
        const p = propDe(q.cls, campo);
        if (p.type === "linkingObjects") continue;
        o[campo] = converter(p, valor);
      }
    });
    return { key: chave(o), valores: objetoParaJSON(o, false) };
  },
  criar(q) {
    const valores = {};
    const s = realm.schema.find((x) => x.name === q.cls);
    const pk = s && s.primaryKey;
    if (pk && (q.valores[pk] === undefined || q.valores[pk] === null || q.valores[pk] === "")) {
      const t = s.properties[pk].type;
      if (t === "objectId") q.valores[pk] = new BSON.ObjectId().toHexString();
      else if (t === "uuid") q.valores[pk] = new BSON.UUID().toHexString(true);
    }
    for (const [campo, valor] of Object.entries(q.valores)) {
      const p = propDe(q.cls, campo);
      if (valor === undefined || p.type === "linkingObjects") continue;
      valores[campo] = converter(p, valor);
    }
    let novo;
    realm.write(() => { novo = realm.create(q.cls, valores); });
    return { key: chave(novo) };
  },
  apagar(q) {
    let n = 0;
    realm.write(() => {
      for (const k of q.keys) { const o = realm._objectForObjectKey(q.cls, String(k)); if (o && o.isValid()) { realm.delete(o); n++; } }
    });
    return { apagados: n };
  },
  apagarFiltrados(q) {
    const r = resultados(q);
    const n = r.length;
    realm.write(() => realm.delete(r));
    return { apagados: n };
  },
  exportar(q) {
    const r = resultados(q);
    const lista = [...r].map((o) => ({ _key: chave(o), ...objetoParaJSON(o, false) }));
    if (q.formato === "csv") {
      const s = realm.schema.find((x) => x.name === q.cls);
      const cols = Object.keys(s.properties).filter((p) => s.properties[p].type !== "linkingObjects");
      const cel = (v) => {
        if (v === null || v === undefined) return "";
        if (typeof v === "object") v = v.$date || v.$oid || v.$uuid || v.$decimal || (v.$link ? v.label : v.$list !== undefined ? JSON.stringify(v.itens.map((x) => (x && x.$link ? x.label : x))) : v.$dict !== undefined ? JSON.stringify(v.valores) : JSON.stringify(v));
        const t = String(v);
        return /[",\n;]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
      };
      fs.writeFileSync(q.destino, [cols.join(","), ...lista.map((o) => cols.map((c) => cel(o[c])).join(","))].join("\n"));
    } else {
      fs.writeFileSync(q.destino, JSON.stringify(lista, null, 2));
    }
    return { exportados: lista.length };
  },
  copiar(q) {
    if (fs.existsSync(q.destino)) fs.unlinkSync(q.destino);
    realm.writeCopyTo({ path: q.destino });
    return { destino: q.destino };
  },
  fechar() {
    if (realm) { realm.close(); realm = null; }
    return {};
  },
};

// ---------- laço principal ----------

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (linha) => {
  let q;
  try { q = JSON.parse(linha); } catch { return; }
  let resposta;
  try {
    if (!comandos[q.cmd]) throw new Error("comando desconhecido: " + q.cmd);
    if (q.cmd !== "abrir" && !realm) throw new Error("nenhum banco aberto");
    resposta = { id: q.id, ok: true, r: comandos[q.cmd](q) };
  } catch (e) {
    resposta = { id: q.id, ok: false, erro: String((e && e.message) || e) };
  }
  process.stdout.write(JSON.stringify(resposta) + "\n");
});
rl.on("close", () => { try { if (realm) realm.close(); } catch {} process.exit(0); });
process.stdout.write(JSON.stringify({ id: 0, ok: true, r: { pronto: true, versao: require(process.argv[2] + "/package.json").version } }) + "\n");
