-- ============================================================
-- ESQUEMA DO BANCO DE DADOS — Controle de Estoque a Granel
-- Execute este script no SQL Editor do Supabase
-- ============================================================

-- Tabela de perfis de usuários (complementa auth.users do Supabase)
CREATE TABLE IF NOT EXISTS perfis (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  nome TEXT NOT NULL,
  email TEXT NOT NULL,
  papel TEXT NOT NULL DEFAULT 'operador' CHECK (papel IN ('admin','operador')),
  ativo BOOLEAN NOT NULL DEFAULT TRUE,
  criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tabela de configurações (perda de pátio por material)
CREATE TABLE IF NOT EXISTS configuracoes (
  material TEXT PRIMARY KEY,
  perda_pct NUMERIC(5,2) NOT NULL DEFAULT 2.0,
  atualizado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tabela de estoque inicial
CREATE TABLE IF NOT EXISTS estoque_inicial (
  material TEXT PRIMARY KEY,
  quantidade NUMERIC(12,3) NOT NULL DEFAULT 0,
  preco_custo NUMERIC(10,2) NOT NULL DEFAULT 0,
  data_referencia DATE,
  atualizado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tabela principal de movimentações
CREATE TABLE IF NOT EXISTS movimentacoes (
  id BIGSERIAL PRIMARY KEY,
  data DATE NOT NULL,
  tipo TEXT NOT NULL CHECK (tipo IN ('entrada','saida','ajuste')),
  material TEXT NOT NULL,
  peso NUMERIC(12,3) NOT NULL DEFAULT 0,
  preco NUMERIC(10,2) NOT NULL DEFAULT 0,
  total NUMERIC(14,2) NOT NULL DEFAULT 0,
  parte TEXT,
  nota TEXT,
  -- campos específicos de ajuste
  ajuste_delta NUMERIC(12,3),
  ajuste_tipo TEXT,
  est_antes NUMERIC(12,3),
  est_depois NUMERIC(12,3),
  -- auditoria
  usuario_id UUID REFERENCES auth.users(id),
  usuario_nome TEXT,
  criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices para performance
CREATE INDEX IF NOT EXISTS idx_mov_data ON movimentacoes(data);
CREATE INDEX IF NOT EXISTS idx_mov_material ON movimentacoes(material);
CREATE INDEX IF NOT EXISTS idx_mov_tipo ON movimentacoes(tipo);
CREATE INDEX IF NOT EXISTS idx_mov_parte ON movimentacoes(parte);

-- ── Dados iniciais de configuração (todos os materiais) ──
INSERT INTO configuracoes (material, perda_pct) VALUES
  ('Areia Grossa', 2.0),
  ('Areia Fina', 2.0),
  ('Areia de Cava/Amarela', 2.0),
  ('Areia Mista', 2.0),
  ('Areião', 2.0),
  ('Brita 01 (1/2)', 2.0),
  ('Pedrisco de Brita', 2.0)
ON CONFLICT (material) DO NOTHING;

INSERT INTO estoque_inicial (material, quantidade, preco_custo) VALUES
  ('Areia Grossa', 0, 0),
  ('Areia Fina', 0, 0),
  ('Areia de Cava/Amarela', 0, 0),
  ('Areia Mista', 0, 0),
  ('Areião', 0, 0),
  ('Brita 01 (1/2)', 0, 0),
  ('Pedrisco de Brita', 0, 0)
ON CONFLICT (material) DO NOTHING;

-- ── Row Level Security (RLS) — segurança por usuário ──
ALTER TABLE perfis ENABLE ROW LEVEL SECURITY;
ALTER TABLE configuracoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE estoque_inicial ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentacoes ENABLE ROW LEVEL SECURITY;

-- Perfis: usuário vê apenas o próprio perfil; admin vê todos
CREATE POLICY "Usuário vê próprio perfil" ON perfis
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Admin vê todos os perfis" ON perfis
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfis WHERE id = auth.uid() AND papel = 'admin')
  );

-- Configurações e estoque inicial: qualquer usuário autenticado lê; apenas admin altera
CREATE POLICY "Leitura autenticada — configuracoes" ON configuracoes
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin altera configuracoes" ON configuracoes
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfis WHERE id = auth.uid() AND papel = 'admin')
  );

CREATE POLICY "Leitura autenticada — estoque_inicial" ON estoque_inicial
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admin altera estoque_inicial" ON estoque_inicial
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfis WHERE id = auth.uid() AND papel = 'admin')
  );

-- Movimentações: qualquer autenticado lê e insere; apenas admin ou dono exclui/edita
CREATE POLICY "Leitura autenticada — movimentacoes" ON movimentacoes
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Inserção autenticada — movimentacoes" ON movimentacoes
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Admin ou dono edita movimentacao" ON movimentacoes
  FOR UPDATE USING (
    auth.uid() = usuario_id OR
    EXISTS (SELECT 1 FROM perfis WHERE id = auth.uid() AND papel = 'admin')
  );

CREATE POLICY "Admin ou dono exclui movimentacao" ON movimentacoes
  FOR DELETE USING (
    auth.uid() = usuario_id OR
    EXISTS (SELECT 1 FROM perfis WHERE id = auth.uid() AND papel = 'admin')
  );

-- ── Trigger: cria perfil automaticamente ao cadastrar usuário ──
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO perfis (id, nome, email, papel)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'nome', split_part(NEW.email,'@',1)),
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'papel', 'operador')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
