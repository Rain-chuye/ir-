-- AST-based register VM Obfuscation tool for Lua 5.3.3
-- Written in 100% Pure Lua 5.3

local Util = {}
do
    function Util.lookupify(tb)
        for _, v in pairs(tb) do
            tb[v] = true
        end
        return tb
    end

    function Util.CountTable(tb)
        local c = 0
        for _ in pairs(tb) do c = c + 1 end
        return c
    end
end

local Scope = {}
do
    function Scope.new(self, parent)
        local s = {
            Parent = parent,
            Locals = { },
            Globals = { },
            Children = { },
        }
        if parent then
            table.insert(parent.Children, s)
        end
        return setmetatable(s, { __index = self })
    end

    function Scope.AddLocal(self, v)
        table.insert(self.Locals, v)
    end

    function Scope.AddGlobal(self, v)
        table.insert(self.Globals, v)
    end

    function Scope.CreateLocal(self, name)
        local v = self:GetLocal(name)
        if v then return v end
        v = {
            Scope = self,
            Name = name,
            IsGlobal = false,
            References = 1,
            Captured = false
        }
        self:AddLocal(v)
        return v
    end

    function Scope.GetLocal(self, name)
        for _, var in pairs(self.Locals) do
            if var.Name == name then return var end
        end
        if self.Parent then
            return self.Parent:GetLocal(name)
        end
    end

    function Scope.CreateGlobal(self, name)
        local v = self:GetGlobal(name)
        if v then return v end
        v = {
            Scope = self,
            Name = name,
            IsGlobal = true,
            References = 1
        }
        self:AddGlobal(v)
        return v
    end

    function Scope.GetGlobal(self, name)
        for _, v in pairs(self.Globals) do
            if v.Name == name then return v end
        end
        if self.Parent then
            return self.Parent:GetGlobal(name)
        end
    end
end

local function LexLua(src)
    local WhiteChars = Util.lookupify{' ', '\n', '\t', '\r'}
    local LowerChars = Util.lookupify{'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z'}
    local UpperChars = Util.lookupify{'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 's', 't', 'U', 'V', 'W', 'X', 'Y', 'Z'}
    local Digits = Util.lookupify{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9'}
    local HexDigits = Util.lookupify{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'a', 'B', 'b', 'C', 'c', 'D', 'd', 'E', 'e', 'F', 'f'}
    local Symbols = Util.lookupify{'+', '-', '*', '/', '^', '%', ',', '{', '}', '[', ']', '(', ')', ';', '#', '&', '|', '~', '<', '>', '='}
    local Keywords = Util.lookupify{
        'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if',
        'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while'
    }

    local tokens = {}
    local p = 1
    local line = 1
    local char = 1

    local function get()
        local c = src:sub(p,p)
        if c == '\n' then
            char = 1
            line = line + 1
        else
            char = char + 1
        end
        p = p + 1
        return c
    end

    local function peek(n)
        n = n or 0
        return src:sub(p+n,p+n)
    end

    local function consume(chars)
        local c = peek()
        for i = 1, #chars do
            if c == chars:sub(i,i) then return get() end
        end
    end

    local function tryGetLongString()
        local start = p
        if peek() == '[' then
            local equalsCount = 0
            while peek(equalsCount+1) == '=' do
                equalsCount = equalsCount + 1
            end
            if peek(equalsCount+1) == '[' then
                for _ = 0, equalsCount+1 do get() end
                local contentStart = p
                while true do
                    if peek() == '' then
                        error("Unfinished long string near <eof>")
                    end
                    local foundEnd = true
                    if peek() == ']' then
                        for i = 1, equalsCount do
                            if peek(i) ~= '=' then foundEnd = false end
                        end
                        if peek(equalsCount+1) ~= ']' then foundEnd = false end
                    else
                        foundEnd = false
                    end
                    if foundEnd then break else get() end
                end
                local contentString = src:sub(contentStart, p-1)
                for _ = 0, equalsCount+1 do get() end
                return contentString, src:sub(start, p-1)
            end
        end
    end

    while true do
        while true do
            local c = peek()
            if c == ' ' or c == '\t' or c == '\r' or c == '\n' then
                get()
            elseif c == '-' and peek(1) == '-' then
                get(); get()
                local _, whole = tryGetLongString()
                if not whole then
                    while peek() ~= '\n' and peek() ~= '' do get() end
                end
            else
                break
            end
        end

        local thisLine = line
        local thisChar = char
        local c = peek()
        local toEmit = nil

        if c == '' then
            toEmit = { Type = 'Eof' }
        elseif UpperChars[c] or LowerChars[c] or c == '_' or (c ~= '' and string.byte(c) >= 128) then
            local start = p
            repeat
                get()
                c = peek()
            until not (UpperChars[c] or LowerChars[c] or Digits[c] or c == '_' or (c ~= '' and string.byte(c) >= 128))
            local dat = src:sub(start, p-1)
            if Keywords[dat] then
                toEmit = {Type = 'Keyword', Data = dat}
            else
                toEmit = {Type = 'Ident', Data = dat}
            end
        elseif Digits[c] or (peek() == '.' and Digits[peek(1)]) then
            local start = p
            if c == '0' and peek(1) == 'x' then
                get(); get()
                while HexDigits[peek()] do get() end
            else
                while Digits[peek()] do get() end
                if consume('.') then
                    while Digits[peek()] do get() end
                end
                if consume('Ee') then
                    consume('+-')
                    while Digits[peek()] do get() end
                end
            end
            toEmit = {Type = 'Number', Data = src:sub(start, p-1)}
        elseif c == '\'' or c == '\"' then
            local start = p
            local delim = get()
            local contentStart = p
            while true do
                local cur = get()
                if cur == '\\' then
                    get()
                elseif cur == delim then
                    break
                elseif cur == '' then
                    error("Unfinished string near <eof>")
                end
            end
            local content = src:sub(contentStart, p-2)
            toEmit = {Type = 'String', Data = src:sub(start, p-1), Constant = content}
        elseif c == '[' then
            local content, whole = tryGetLongString()
            if whole then
                toEmit = {Type = 'String', Data = whole, Constant = content}
            else
                get()
                toEmit = {Type = 'Symbol', Data = '['}
            end
        elseif consume('>=<~/') then
            local next_c = peek()
            if next_c == '=' then
                get()
                toEmit = {Type = 'Symbol', Data = c..'='}
            elseif c == '<' and next_c == '<' then
                get()
                toEmit = {Type = 'Symbol', Data = '<<'}
            elseif c == '>' and next_c == '>' then
                get()
                toEmit = {Type = 'Symbol', Data = '>>'}
            elseif c == '/' and next_c == '/' then
                get()
                toEmit = {Type = 'Symbol', Data = '//'}
            else
                toEmit = {Type = 'Symbol', Data = c}
            end
        elseif consume('.') then
            if consume('.') then
                if consume('.') then
                    toEmit = {Type = 'Symbol', Data = '...'}
                else
                    toEmit = {Type = 'Symbol', Data = '..'}
                end
            else
                toEmit = {Type = 'Symbol', Data = '.'}
            end
        elseif consume(':') then
            if consume(':') then
                toEmit = {Type = 'Symbol', Data = '::'}
            else
                toEmit = {Type = 'Symbol', Data = ':'}
            end
        elseif Symbols[c] then
            get()
            toEmit = {Type = 'Symbol', Data = c}
        else
            error("Unexpected symbol `" .. c .. "` near line " .. line)
        end

        toEmit.Line = thisLine
        toEmit.Char = thisChar
        table.insert(tokens, toEmit)
        if toEmit.Type == 'Eof' then break end
    end

    local tok = {}
    local savedP = {}
    local tok_p = 1

    function tok:Peek(n)
        n = n or 0
        return tokens[math.min(#tokens, tok_p+n)]
    end

    function tok:Get()
        local t = tokens[tok_p]
        tok_p = math.min(tok_p + 1, #tokens)
        return t
    end

    function tok:Is(t)
        return tok:Peek().Type == t
    end

    function tok:Save()
        table.insert(savedP, tok_p)
    end

    function tok:Commit()
        table.remove(savedP)
    end

    function tok:Restore()
        tok_p = table.remove(savedP)
    end

    function tok:ConsumeSymbol(symb)
        local t = self:Peek()
        if t.Type == 'Symbol' then
            if symb then
                if t.Data == symb then
                    self:Get()
                    return true
                else
                    return nil
                end
            else
                self:Get()
                return t
            end
        end
    end

    function tok:ConsumeKeyword(kw)
        local t = self:Peek()
        if t.Type == 'Keyword' and t.Data == kw then
            self:Get()
            return true
        end
    end

    function tok:IsKeyword(kw)
        local t = self:Peek()
        return t.Type == 'Keyword' and t.Data == kw
    end

    function tok:IsSymbol(s)
        local t = self:Peek()
        return t.Type == 'Symbol' and t.Data == s
    end

    function tok:IsEof()
        return self:Peek().Type == 'Eof'
    end

    return true, tok
end

local function ParseLua(src)
    local st, tok = LexLua(src)
    if not st then return false, tok end

    local ParseExpr
    local ParseStatementList
    local ParseSimpleExpr
    local ParseSubExpr
    local ParsePrimaryExpr
    local ParseSuffixedExpr

    local function CreateScope(parent)
        return Scope:new(parent)
    end

    local function ParseFunctionArgsAndBody(scope)
        local funcScope = CreateScope(scope)
        if not tok:ConsumeSymbol('(') then
            error("`(` expected near function arguments.")
        end

        local argList = {}
        local isVarArg = false
        while not tok:ConsumeSymbol(')') do
            if tok:Is('Ident') then
                local arg = funcScope:CreateLocal(tok:Get().Data)
                table.insert(argList, arg)
                if not tok:ConsumeSymbol(',') then
                    if tok:ConsumeSymbol(')') then break else error("`)` expected.") end
                end
            elseif tok:ConsumeSymbol('...') then
                isVarArg = true
                if not tok:ConsumeSymbol(')') then
                    error("`...` must be the last argument of a function.")
                end
                break
            else
                error("Argument name or `...` expected")
            end
        end

        local st, body = ParseStatementList(funcScope)
        if not st then error(body) end

        if not tok:ConsumeKeyword('end') then
            error("`end` expected after function body")
        end

        return true, {
            AstType = 'Function',
            Scope = funcScope,
            Arguments = argList,
            Body = body,
            VarArg = isVarArg
        }
    end

    function ParsePrimaryExpr(scope)
        if tok:ConsumeSymbol('(') then
            local st, ex = ParseExpr(scope)
            if not st then error(ex) end
            if not tok:ConsumeSymbol(')') then error("`)` Expected.") end
            return true, {
                AstType = 'Parentheses',
                Inner = ex
            }
        elseif tok:Is('Ident') then
            local id = tok:Get()
            local var = scope:GetLocal(id.Data)
            if not var then
                var = scope:GetGlobal(id.Data) or scope:CreateGlobal(id.Data)
            end
            return true, {
                AstType = 'VarExpr',
                Name = id.Data,
                Variable = var
            }
        else
            error("Primary expression expected")
        end
    end

    function ParseSuffixedExpr(scope, onlyDotColon)
        local st, prim = ParsePrimaryExpr(scope)
        if not st then error(prim) end

        while true do
            if tok:IsSymbol('.') or tok:IsSymbol(':') then
                local symb = tok:Get().Data
                if not tok:Is('Ident') then error("<Ident> expected.") end
                local id = tok:Get()
                prim = {
                    AstType = 'MemberExpr',
                    Base = prim,
                    Indexer = symb,
                    Ident = id
                }
            elseif not onlyDotColon and tok:ConsumeSymbol('[') then
                local st, ex = ParseExpr(scope)
                if not st then error(ex) end
                if not tok:ConsumeSymbol(']') then error("`]` expected.") end
                prim = {
                    AstType = 'IndexExpr',
                    Base = prim,
                    Index = ex
                }
            elseif not onlyDotColon and tok:ConsumeSymbol('(') then
                local args = {}
                while not tok:ConsumeSymbol(')') do
                    local st, ex = ParseExpr(scope)
                    if not st then error(ex) end
                    table.insert(args, ex)
                    if not tok:ConsumeSymbol(',') then
                        if tok:ConsumeSymbol(')') then break else error("`)` Expected.") end
                    end
                end
                prim = {
                    AstType = 'CallExpr',
                    Base = prim,
                    Arguments = args
                }
            elseif not onlyDotColon and tok:Is('String') then
                prim = {
                    AstType = 'StringCallExpr',
                    Base = prim,
                    Arguments = { tok:Get() }
                }
            elseif not onlyDotColon and tok:IsSymbol('{') then
                local st, ex = ParseSimpleExpr(scope)
                if not st then error(ex) end
                prim = {
                    AstType = 'TableCallExpr',
                    Base = prim,
                    Arguments = { ex }
                }
            else
                break
            end
        end
        return true, prim
    end

    function ParseSimpleExpr(scope)
        if tok:Is('Number') then
            return true, { AstType = 'NumberExpr', Value = tok:Get() }
        elseif tok:Is('String') then
            return true, { AstType = 'StringExpr', Value = tok:Get() }
        elseif tok:ConsumeKeyword('nil') then
            return true, { AstType = 'NilExpr' }
        elseif tok:IsKeyword('false') or tok:IsKeyword('true') then
            return true, { AstType = 'BooleanExpr', Value = (tok:Get().Data == 'true') }
        elseif tok:ConsumeSymbol('...') then
            return true, { AstType = 'DotsExpr' }
        elseif tok:ConsumeSymbol('{') then
            local v = { AstType = 'ConstructorExpr', EntryList = {} }
            while true do
                if tok:IsSymbol('[') then
                    tok:Get()
                    local st, key = ParseExpr(scope)
                    if not st then error("Key Expression Expected") end
                    if not tok:ConsumeSymbol(']') then error("`]` Expected") end
                    if not tok:ConsumeSymbol('=') then error("`=` Expected") end
                    local st, value = ParseExpr(scope)
                    if not st then error("Value Expression Expected") end
                    table.insert(v.EntryList, { Type = 'Key', Key = key, Value = value })
                elseif tok:Is('Ident') then
                    local lookahead = tok:Peek(1)
                    if lookahead.Type == 'Symbol' and lookahead.Data == '=' then
                        local key = tok:Get()
                        tok:Get()
                        local st, value = ParseExpr(scope)
                        if not st then error("Value Expression Expected") end
                        table.insert(v.EntryList, { Type = 'KeyString', Key = key.Data, Value = value })
                    else
                        local st, value = ParseExpr(scope)
                        if not st then error("Value Expected") end
                        table.insert(v.EntryList, { Type = 'Value', Value = value })
                    end
                elseif tok:ConsumeSymbol('}') then
                    break
                else
                    local st, value = ParseExpr(scope)
                    if not st then error("Value Expected") end
                    table.insert(v.EntryList, { Type = 'Value', Value = value })
                end

                if tok:ConsumeSymbol(';') or tok:ConsumeSymbol(',') then
                    -- good
                elseif tok:ConsumeSymbol('}') then
                    break
                else
                    error("`}` or table entry Expected")
                end
            end
            return true, v
        elseif tok:ConsumeKeyword('function') then
            local st, func = ParseFunctionArgsAndBody(scope)
            if not st then error(func) end
            func.IsLocal = true
            return true, func
        else
            return ParseSuffixedExpr(scope)
        end
    end

    local unops = Util.lookupify{'-', 'not', '#', '~'}
    local unopprio = 8
    local priority = {
        ['+'] = {6,6}, ['-'] = {6,6}, ['%'] = {7,7}, ['/'] = {7,7}, ['*'] = {7,7},
        ['^'] = {10,9}, ['..'] = {5,4}, ['=='] = {3,3}, ['<'] = {3,3}, ['<='] = {3,3},
        ['~='] = {3,3}, ['>'] = {3,3}, ['>='] = {3,3}, ['and'] = {2,2}, ['or'] = {1,1},
        ['&'] = {6,6}, ['|'] = {6,6}, ['~'] = {6,6}, ['<<'] = {6,6}, ['>>'] = {6,6}, ['//'] = {7,7}
    }

    function ParseSubExpr(scope, level)
        local st, exp
        if unops[tok:Peek().Data] then
            local op = tok:Get().Data
            st, exp = ParseSubExpr(scope, unopprio)
            if not st then error(exp) end
            exp = {
                AstType = 'UnopExpr',
                Rhs = exp,
                Op = op,
                OperatorPrecedence = unopprio
            }
        else
            st, exp = ParseSimpleExpr(scope)
            if not st then error(exp) end
        end

        while true do
            local prio = priority[tok:Peek().Data]
            if prio and prio[1] > level then
                local op = tok:Get().Data
                local st, rhs = ParseSubExpr(scope, prio[2])
                if not st then error(rhs) end
                exp = {
                    AstType = 'BinopExpr',
                    Lhs = exp,
                    Op = op,
                    OperatorPrecedence = prio[1],
                    Rhs = rhs
                }
            else
                break
            end
        end

        return true, exp
    end

    ParseExpr = function(scope)
        return ParseSubExpr(scope, 0)
    end

    local function ParseStatement(scope)
        local stat = nil
        if tok:ConsumeKeyword('if') then
            local nodeIfStat = { AstType = 'IfStatement', Clauses = {} }
            repeat
                local st, nodeCond = ParseExpr(scope)
                if not st then error(nodeCond) end
                if not tok:ConsumeKeyword('then') then error("`then` expected.") end
                local st, nodeBody = ParseStatementList(scope)
                if not st then error(nodeBody) end
                table.insert(nodeIfStat.Clauses, { Condition = nodeCond, Body = nodeBody })
            until not tok:ConsumeKeyword('elseif')

            if tok:ConsumeKeyword('else') then
                local st, nodeBody = ParseStatementList(scope)
                if not st then error(nodeBody) end
                table.insert(nodeIfStat.Clauses, { Body = nodeBody })
            end

            if not tok:ConsumeKeyword('end') then error("`end` expected.") end
            stat = nodeIfStat

        elseif tok:ConsumeKeyword('while') then
            local st, nodeCond = ParseExpr(scope)
            if not st then error(nodeCond) end
            if not tok:ConsumeKeyword('do') then error("`do` expected.") end
            local st, nodeBody = ParseStatementList(scope)
            if not st then error(nodeBody) end
            if not tok:ConsumeKeyword('end') then error("`end` expected.") end
            stat = { AstType = 'WhileStatement', Condition = nodeCond, Body = nodeBody }

        elseif tok:ConsumeKeyword('do') then
            local st, nodeBlock = ParseStatementList(scope)
            if not st then error(nodeBlock) end
            if not tok:ConsumeKeyword('end') then error("`end` expected.") end
            stat = { AstType = 'DoStatement', Body = nodeBlock }

        elseif tok:ConsumeKeyword('for') then
            if not tok:Is('Ident') then error("<ident> expected.") end
            local baseVarName = tok:Get()
            if tok:ConsumeSymbol('=') then
                local forScope = CreateScope(scope)
                local forVar = forScope:CreateLocal(baseVarName.Data)
                local st, startEx = ParseExpr(scope)
                if not st then error(startEx) end
                if not tok:ConsumeSymbol(',') then error("`,` Expected") end
                local st, endEx = ParseExpr(scope)
                if not st then error(endEx) end
                local st, stepEx
                if tok:ConsumeSymbol(',') then
                    st, stepEx = ParseExpr(scope)
                    if not st then error(stepEx) end
                end
                if not tok:ConsumeKeyword('do') then error("`do` expected") end
                local st, body = ParseStatementList(forScope)
                if not st then error(body) end
                if not tok:ConsumeKeyword('end') then error("`end` expected") end
                stat = {
                    AstType = 'NumericForStatement',
                    Scope = forScope,
                    Variable = forVar,
                    Start = startEx,
                    End = endEx,
                    Step = stepEx,
                    Body = body
                }
            else
                local forScope = CreateScope(scope)
                local varList = { forScope:CreateLocal(baseVarName.Data) }
                while tok:ConsumeSymbol(',') do
                    if not tok:Is('Ident') then error("for variable expected.") end
                    table.insert(varList, forScope:CreateLocal(tok:Get().Data))
                end
                if not tok:ConsumeKeyword('in') then error("`in` expected.") end
                local generators = {}
                local st, firstGenerator = ParseExpr(scope)
                if not st then error(firstGenerator) end
                table.insert(generators, firstGenerator)
                while tok:ConsumeSymbol(',') do
                    local st, gen = ParseExpr(scope)
                    if not st then error(gen) end
                    table.insert(generators, gen)
                end
                if not tok:ConsumeKeyword('do') then error("`do` expected.") end
                local st, body = ParseStatementList(forScope)
                if not st then error(body) end
                if not tok:ConsumeKeyword('end') then error("`end` expected.") end
                stat = {
                    AstType = 'GenericForStatement',
                    Scope = forScope,
                    VariableList = varList,
                    Generators = generators,
                    Body = body
                }
            end

        elseif tok:ConsumeKeyword('repeat') then
            local st, body = ParseStatementList(scope)
            if not st then error(body) end
            if not tok:ConsumeKeyword('until') then error("`until` expected.") end
            local st, cond = ParseExpr(body.Scope)
            if not st then error(cond) end
            stat = { AstType = 'RepeatStatement', Condition = cond, Body = body }

        elseif tok:ConsumeKeyword('function') then
            if not tok:Is('Ident') then error("Function name expected") end
            local st, name = ParseSuffixedExpr(scope, true)
            if not st then error(name) end
            local st, func = ParseFunctionArgsAndBody(scope)
            if not st then error(func) end
            func.IsLocal = false
            func.Name = name
            stat = func

        elseif tok:ConsumeKeyword('local') then
            if tok:Is('Ident') then
                local varList = { tok:Get().Data }
                while tok:ConsumeSymbol(',') do
                    if not tok:Is('Ident') then error("local var name expected") end
                    table.insert(varList, tok:Get().Data)
                end
                local initList = {}
                if tok:ConsumeSymbol('=') then
                    repeat
                        local st, ex = ParseExpr(scope)
                        if not st then error(ex) end
                        table.insert(initList, ex)
                    until not tok:ConsumeSymbol(',')
                end
                for i, v in ipairs(varList) do
                    varList[i] = scope:CreateLocal(v)
                end
                stat = {
                    AstType = 'LocalStatement',
                    LocalList = varList,
                    InitList = initList
                }
            elseif tok:ConsumeKeyword('function') then
                if not tok:Is('Ident') then error("Function name expected") end
                local name = tok:Get().Data
                local localVar = scope:CreateLocal(name)
                local st, func = ParseFunctionArgsAndBody(scope)
                if not st then error(func) end
                func.Name = localVar
                func.IsLocal = true
                stat = func
            else
                error("local var or function def expected")
            end

        elseif tok:ConsumeSymbol('::') then
            if not tok:Is('Ident') then error('Label name expected') end
            local label = tok:Get().Data
            if not tok:ConsumeSymbol('::') then error("`::` expected") end
            stat = { AstType = 'LabelStatement', Label = label }

        elseif tok:ConsumeKeyword('return') then
            local exList = {}
            if not tok:IsKeyword('end') then
                local st, firstEx = ParseExpr(scope)
                if st then
                    table.insert(exList, firstEx)
                    while tok:ConsumeSymbol(',') do
                        local st, ex = ParseExpr(scope)
                        if not st then error(ex) end
                        table.insert(exList, ex)
                    end
                end
            end
            stat = { AstType = 'ReturnStatement', Arguments = exList }

        elseif tok:ConsumeKeyword('break') then
            stat = { AstType = 'BreakStatement' }

        elseif tok:ConsumeKeyword('goto') then
            if not tok:Is('Ident') then error("Label expected") end
            stat = { AstType = 'GotoStatement', Label = tok:Get().Data }

        else
            local st, suffixed = ParseSuffixedExpr(scope)
            if not st then error(suffixed) end

            if tok:IsSymbol(',') or tok:IsSymbol('=') then
                local lhs = { suffixed }
                while tok:ConsumeSymbol(',') do
                    local st, lhsPart = ParseSuffixedExpr(scope)
                    if not st then error(lhsPart) end
                    table.insert(lhs, lhsPart)
                end
                if not tok:ConsumeSymbol('=') then error("`=` Expected.") end
                local rhs = {}
                local st, firstRhs = ParseExpr(scope)
                if not st then error(firstRhs) end
                table.insert(rhs, firstRhs)
                while tok:ConsumeSymbol(',') do
                    local st, rhsPart = ParseExpr(scope)
                    if not st then error(rhsPart) end
                    table.insert(rhs, rhsPart)
                end
                stat = { AstType = 'AssignmentStatement', Lhs = lhs, Rhs = rhs }
            elseif suffixed.AstType == 'CallExpr' or suffixed.AstType == 'TableCallExpr' or suffixed.AstType == 'StringCallExpr' then
                stat = { AstType = 'CallStatement', Expression = suffixed }
            else
                error("Assignment Statement Expected")
            end
        end

        if tok:IsSymbol(';') then tok:Get() end
        return true, stat
    end

    local statListCloseKeywords = Util.lookupify{'end', 'else', 'elseif', 'until'}

    ParseStatementList = function(scope)
        local nodeStatlist = {
            Scope = CreateScope(scope),
            AstType = 'Statlist',
            Body = {}
        }
        while not statListCloseKeywords[tok:Peek().Data] and not tok:IsEof() do
            local st, nodeStatement = ParseStatement(nodeStatlist.Scope)
            if not st then error(nodeStatement) end
            table.insert(nodeStatlist.Body, nodeStatement)
        end
        return true, nodeStatlist
    end

    local topScope = CreateScope()
    local st, main = ParseStatementList(topScope)
    return st, main
end

local function apply_mba(node)
    if not node then return end

    if node.AstType == 'BinopExpr' then
        node.Lhs = apply_mba(node.Lhs)
        node.Rhs = apply_mba(node.Rhs)

        local op = node.Op
        if op == '&' then
            node.Op = '-'
            node.Lhs = { AstType = 'BinopExpr', Lhs = node.Lhs, Op = '|', Rhs = node.Rhs }
            node.Rhs = { AstType = 'BinopExpr', Lhs = node.Lhs.Lhs, Op = '~', Rhs = node.Rhs }
        elseif op == '~' and node.Lhs.AstType ~= 'UnopExpr' then
            node.Op = '-'
            node.Lhs = { AstType = 'BinopExpr', Lhs = node.Lhs, Op = '|', Rhs = node.Rhs }
            node.Rhs = { AstType = 'BinopExpr', Lhs = node.Lhs.Lhs, Op = '&', Rhs = node.Rhs }
        elseif op == '|' then
            node.Op = '+'
            node.Lhs = { AstType = 'BinopExpr', Lhs = node.Lhs, Op = '&', Rhs = { AstType = 'UnopExpr', Rhs = node.Rhs, Op = '~' } }
        elseif op == '+' and math.random() < 0.5 then
            node.Lhs = { AstType = 'BinopExpr', Lhs = node.Lhs, Op = '|', Rhs = node.Rhs }
            node.Rhs = { AstType = 'BinopExpr', Lhs = node.Lhs.Lhs, Op = '&', Rhs = node.Rhs }
        elseif op == '-' and math.random() < 0.5 then
            node.Op = '-'
            node.Lhs = { AstType = 'BinopExpr', Lhs = node.Lhs, Op = '~', Rhs = node.Rhs }
            node.Rhs = {
                AstType = 'BinopExpr',
                Lhs = { AstType = 'NumberExpr', Value = { Data = "2" } },
                Op = '*',
                Rhs = { AstType = 'BinopExpr', Lhs = { AstType = 'UnopExpr', Rhs = node.Lhs.Lhs, Op = '~' }, Op = '&', Rhs = node.Rhs }
            }
        end
    elseif node.AstType == 'UnopExpr' then
        node.Rhs = apply_mba(node.Rhs)
        if node.Op == '~' then
            node.AstType = 'BinopExpr'
            node.Lhs = { AstType = 'UnopExpr', Rhs = node.Rhs, Op = '-' }
            node.Op = '-'
            node.Rhs = { AstType = 'NumberExpr', Value = { Data = "1" } }
        end
    else
        for k, v in pairs(node) do
            if type(v) == 'table' then
                if v.AstType then
                    node[k] = apply_mba(v)
                else
                    for i, child in ipairs(v) do
                        if type(child) == 'table' and child.AstType then
                            v[i] = apply_mba(child)
                        end
                    end
                end
            end
        end
    end
    return node
end

local function mark_captured_variables(node, current_func_scope)
    if not node then return end
    if node.AstType == 'Function' then
        mark_captured_variables(node.Body, node.Scope)
    elseif node.AstType == 'VarExpr' then
        local var = node.Variable
        if var and not var.IsGlobal then
            local is_ancestor = false
            local s = current_func_scope.Parent
            while s do
                if s == var.Scope then is_ancestor = true; break end
                s = s.Parent
            end
            if is_ancestor then
                var.Captured = true
            end
        end
    else
        for _, v in pairs(node) do
            if type(v) == 'table' then
                if v.AstType then
                    mark_captured_variables(v, current_func_scope)
                else
                    for _, child in ipairs(v) do
                        if type(child) == 'table' and child.AstType then
                            mark_captured_variables(child, current_func_scope)
                        end
                    end
                end
            end
        end
    end
end

local CompilerEnv = {}
do
    function CompilerEnv.new(parent, scope)
        local env = {
            parent = parent,
            scope = scope,
            locals = {},
            upvalues = {},
            reg_top = 0,
            break_targets = {},
            labels = {},
            gotos = {},
            num_params = 0,
            is_vararg = false
        }

        function env.alloc_reg(self, count)
            count = count or 1
            local r = self.reg_top
            self.reg_top = self.reg_top + count
            return r
        end

        function env.get_max_local_reg(self)
            local max_reg = -1
            for var_obj, r in pairs(self.locals) do
                if r > max_reg then
                    max_reg = r
                end
            end
            return max_reg
        end

        function env.free_reg(self, r)
            local min_top = self:get_max_local_reg() + 1
            local target_top = r
            if target_top < min_top then
                target_top = min_top
            end
            if target_top < self.reg_top then
                self.reg_top = target_top
            end
        end

        function env.declare_local(self, var_obj)
            local r = self:alloc_reg()
            self.locals[var_obj] = r
            return r
        end

        function env.resolve_var(self, var_obj)
            local is_self = (var_obj and var_obj.Name == "self")

            for local_var, reg in pairs(self.locals) do
                if local_var == var_obj or (is_self and local_var.Name == "self") then
                    return { type = "local", reg = reg, captured = local_var.Captured }
                end
            end

            if self.parent then
                local res = self.parent:resolve_var(var_obj)
                if res then
                    if res.type == "local" or res.type == "upval" then
                        for idx, up in ipairs(self.upvalues) do
                            if up.var_obj == var_obj or (is_self and up.var_obj.Name == "self") then
                                return { type = "upval", index = idx - 1 }
                            end
                        end
                        local up_desc = {
                            var_obj = var_obj,
                            type = res.type,
                            index = (res.type == "local") and res.reg or res.index
                        }
                        table.insert(self.upvalues, up_desc)
                        return { type = "upval", index = #self.upvalues - 1 }
                    end
                end
            end
        end

        return env
    end
end

local function compile_ast(opcodes, use_storm, global_protos, global_protos_B, is_B)
    local compiler = {
        opcodes = opcodes,
        use_storm = use_storm,
        global_protos = global_protos or {},
        global_protos_B = global_protos_B or {},
        is_B = is_B or false
    }

    local code = {}
    local consts = {}
    local const_map = {}

    local function add_const(val)
        if const_map[val] then return const_map[val] end
        table.insert(consts, val)
        local idx = #consts - 1
        const_map[val] = idx
        return idx
    end

    local function emit(env, action, a, b, c)
        a = a or 0
        b = b or 0
        c = c or 0
        local op = opcodes[action]
        if not op then error("Unknown action: " .. tostring(action)) end

        local integrity_hash = 0
        local pc = #code + 1
        if action == "JMP" or action == "CALL" then
            integrity_hash = (pc * 31 + op * 17) % 10000007
        end
        table.insert(code, { op, a, b, c, integrity_hash, action })
        return #code
    end

    local compile_expr, compile_stmt, compile_Block

    function compile_Block(block_node, env)
        for _, stmt in ipairs(block_node.Body) do
            compile_stmt(stmt, env)
        end
    end

    function compile_stmt(node, env)
        if node.AstType == 'LocalStatement' then
            local target_regs = {}
            for i, var_obj in ipairs(node.LocalList) do
                local r = env:declare_local(var_obj)
                target_regs[i] = r
            end

            local num_targets = #node.LocalList
            local num_inits = #node.InitList
            local has_mult_ret = false

            for i, val in ipairs(node.InitList) do
                local dest_r
                if i < num_inits then
                    if i <= num_targets then
                        dest_r = target_regs[i]
                    else
                        dest_r = env:alloc_reg()
                    end
                    compile_expr(val, dest_r, env)
                    if i > num_targets then
                        env:free_reg(dest_r)
                    end
                else
                    if i <= num_targets then
                        dest_r = target_regs[i]
                    else
                        dest_r = env:alloc_reg()
                    end

                    if val.AstType == 'CallExpr' or val.AstType == 'TableCallExpr' or val.AstType == 'StringCallExpr' or val.AstType == 'DotsExpr' then
                        compile_expr(val, dest_r, env, true)
                        has_mult_ret = true
                    else
                        compile_expr(val, dest_r, env)
                    end

                    if i > num_targets then
                        env:free_reg(dest_r)
                    end
                end
            end

            if not has_mult_ret then
                for i = num_inits + 1, num_targets do
                    emit(env, "LOADNIL", target_regs[i])
                end
            end

            for _, var_obj in ipairs(node.LocalList) do
                if var_obj.Captured then
                    local r = env.locals[var_obj]
                    emit(env, "MAKECELL", r, r)
                end
            end

        elseif node.AstType == 'AssignmentStatement' then
            local regs = {}
            for _, val in ipairs(node.Rhs) do
                if val.AstType == 'CallExpr' or val.AstType == 'TableCallExpr' or val.AstType == 'StringCallExpr' or val.AstType == 'DotsExpr' then
                    local r = env:alloc_reg()
                    compile_expr(val, r, env, true)
                    table.insert(regs, { r, -1 })
                else
                    local r = env:alloc_reg()
                    compile_expr(val, r, env)
                    table.insert(regs, { r, 1 })
                end
            end

            local has_mult_ret = (#regs > 0 and regs[#regs][2] == -1)
            local mult_ret_reg = has_mult_ret and regs[#regs][1] or nil

            for i, target in ipairs(node.Lhs) do
                local val_reg
                if has_mult_ret and i >= #regs then
                    val_reg = mult_ret_reg + (i - #regs)
                else
                    if i <= #regs then
                        val_reg = regs[i][1]
                    else
                        val_reg = env:alloc_reg()
                        emit(env, "LOADNIL", val_reg)
                    end
                end

                if target.AstType == 'VarExpr' then
                    local res = env:resolve_var(target.Variable)
                    if not res or res.type == "global" then
                        local k = add_const(target.Name)
                        emit(env, "SETGLOBAL", val_reg, k)
                    elseif res.type == "local" then
                        if res.captured then
                            emit(env, "SETTABLE_1", val_reg, res.reg)
                        else
                            emit(env, "MOVE", res.reg, val_reg)
                        end
                    elseif res.type == "upval" then
                        emit(env, "SETUPVAL", val_reg, res.index)
                    end
                elseif target.AstType == 'IndexExpr' or target.AstType == 'MemberExpr' then
                    local t_reg = env:alloc_reg()
                    compile_expr(target.Base, t_reg, env)
                    local idx_reg = env:alloc_reg()
                    if target.AstType == 'MemberExpr' then
                        compile_expr({ AstType = 'StringExpr', Value = { Constant = target.Ident.Data } }, idx_reg, env)
                    else
                        compile_expr(target.Index, idx_reg, env)
                    end
                    emit(env, "SETTABLE", t_reg, idx_reg, val_reg)
                    env:free_reg(t_reg)
                    env:free_reg(idx_reg)
                end

                if not (has_mult_ret and i >= #regs) then
                    if i > #regs then env:free_reg(val_reg) end
                end
            end

            for _, info in ipairs(regs) do
                env:free_reg(info[1])
            end

        elseif node.AstType == 'IfStatement' then
            local end_jmps = {}
            for _, clause in ipairs(node.Clauses) do
                if clause.Condition then
                    local cond_reg = env:alloc_reg()
                    compile_expr(clause.Condition, cond_reg, env)

                    emit(env, "TEST", cond_reg, 0)
                    local skip_jmp_idx = #code + 1
                    emit(env, "JMP", 0, 0)
                    env:free_reg(cond_reg)

                    compile_Block(clause.Body, env)
                    local end_jmp_pc = emit(env, "JMP", 0, 0)
                    table.insert(end_jmps, end_jmp_pc)

                    local next_branch_pc = #code + 1
                    code[skip_jmp_idx][3] = next_branch_pc - skip_jmp_idx - 1
                else
                    compile_Block(clause.Body, env)
                end
            end
            local end_pc = #code + 1
            for _, pc in ipairs(end_jmps) do
                code[pc][3] = end_pc - pc - 1
            end

        elseif node.AstType == 'WhileStatement' then
            local start_pc = #code + 1
            local cond_reg = env:alloc_reg()
            compile_expr(node.Condition, cond_reg, env)

            emit(env, "TEST", cond_reg, 0)
            local skip_jmp_idx = #code + 1
            emit(env, "JMP", 0, 0)
            env:free_reg(cond_reg)

            table.insert(env.break_targets, {})
            compile_Block(node.Body, env)

            emit(env, "JMP", 0, start_pc - #code - 1)

            local end_pc = #code + 1
            code[skip_jmp_idx][3] = end_pc - skip_jmp_idx - 1
            for _, break_pc in ipairs(table.remove(env.break_targets)) do
                code[break_pc][3] = end_pc - break_pc - 1
            end

        elseif node.AstType == 'RepeatStatement' then
            local start_pc = #code + 1
            table.insert(env.break_targets, {})
            compile_Block(node.Body, env)

            local cond_reg = env:alloc_reg()
            compile_expr(node.Condition, cond_reg, env)

            emit(env, "TEST", cond_reg, 1)
            local skip_jmp_idx = #code + 1
            emit(env, "JMP", 0, 0)

            emit(env, "JMP", 0, start_pc - #code - 1)

            local end_pc = #code + 1
            code[skip_jmp_idx][3] = end_pc - skip_jmp_idx - 1
            env:free_reg(cond_reg)

            for _, break_pc in ipairs(table.remove(env.break_targets)) do
                code[break_pc][3] = end_pc - break_pc - 1
            end

        elseif node.AstType == 'DoStatement' then
            compile_Block(node.Body, env)

        elseif node.AstType == 'NumericForStatement' then
            local _i = env:alloc_reg()
            compile_expr(node.Start, _i, env)
            local _stop = env:alloc_reg()
            compile_expr(node.End, _stop, env)
            local _step = env:alloc_reg()
            if node.Step then
                compile_expr(node.Step, _step, env)
            else
                emit(env, "LOADK", _step, add_const(1))
            end

            local start_pc = #code + 1
            local cond_reg = env:alloc_reg()

            local s_gt_0 = env:alloc_reg()
            local zero_reg = env:alloc_reg()
            emit(env, "LOADK", zero_reg, add_const(0))
            emit(env, "LT", 1, zero_reg, _step)
            emit(env, "LOADBOOL", s_gt_0, 1, 1)
            emit(env, "LOADBOOL", s_gt_0, 0, 0)

            local i_le_stop = env:alloc_reg()
            emit(env, "LE", 1, _i, _stop)
            emit(env, "LOADBOOL", i_le_stop, 1, 1)
            emit(env, "LOADBOOL", i_le_stop, 0, 0)

            local cond1 = env:alloc_reg()
            emit(env, "BAND", cond1, s_gt_0, i_le_stop)

            local s_le_0 = env:alloc_reg()
            emit(env, "LE", 1, _step, zero_reg)
            emit(env, "LOADBOOL", s_le_0, 1, 1)
            emit(env, "LOADBOOL", s_le_0, 0, 0)

            local i_ge_stop = env:alloc_reg()
            emit(env, "LE", 1, _stop, _i)
            emit(env, "LOADBOOL", i_ge_stop, 1, 1)
            emit(env, "LOADBOOL", i_ge_stop, 0, 0)

            local cond2 = env:alloc_reg()
            emit(env, "BAND", cond2, s_le_0, i_ge_stop)

            emit(env, "BOR", cond_reg, cond1, cond2)
            emit(env, "TEST", cond_reg, 0)
            local skip_jmp_idx = #code + 1
            emit(env, "JMP", 0, 0)

            env:free_reg(cond_reg)
            env:free_reg(s_gt_0)
            env:free_reg(zero_reg)
            env:free_reg(i_le_stop)
            env:free_reg(cond1)
            env:free_reg(s_le_0)
            env:free_reg(i_ge_stop)
            env:free_reg(cond2)

            local user_reg = env:declare_local(node.Variable)
            emit(env, "MOVE", user_reg, _i)
            if node.Variable.Captured then
                emit(env, "MAKECELL", user_reg, user_reg)
            end

            table.insert(env.break_targets, {})
            compile_Block(node.Body, env)

            emit(env, "ADD", _i, _i, _step)
            emit(env, "JMP", 0, start_pc - #code - 1)

            local end_pc = #code + 1
            code[skip_jmp_idx][3] = end_pc - skip_jmp_idx - 1
            for _, break_pc in ipairs(table.remove(env.break_targets)) do
                code[break_pc][3] = end_pc - break_pc - 1
            end

            env:free_reg(_i)
            env:free_reg(_stop)
            env:free_reg(_step)

        elseif node.AstType == 'GenericForStatement' then
            local _iter = env:alloc_reg()
            local _state = env:alloc_reg()
            local _var = env:alloc_reg()

            local regs = {}
            for _, val in ipairs(node.Generators) do
                local r = env:alloc_reg()
                compile_expr(val, r, env, true)
                table.insert(regs, r)
            end

            if #regs >= 1 then emit(env, "MOVE", _iter, regs[1]) else emit(env, "LOADNIL", _iter) end
            if #regs >= 2 then emit(env, "MOVE", _state, regs[2]) else emit(env, "LOADNIL", _state) end
            if #regs >= 3 then emit(env, "MOVE", _var, regs[3]) else emit(env, "LOADNIL", _var) end

            for _, r in ipairs(regs) do env:free_reg(r) end

            local start_pc = #code + 1
            local call_reg = env:alloc_reg()
            emit(env, "MOVE", call_reg, _iter)
            local state_arg = env:alloc_reg()
            emit(env, "MOVE", state_arg, _state)
            local var_arg = env:alloc_reg()
            emit(env, "MOVE", var_arg, _var)

            local num_targets = #node.VariableList
            emit(env, "CALL", call_reg, 2, num_targets)

            emit(env, "MOVE", _var, call_reg)
            emit(env, "TEST", _var, 0)
            local skip_jmp_idx = #code + 1
            emit(env, "JMP", 0, 0)

            env:free_reg(call_reg)
            env:free_reg(state_arg)
            env:free_reg(var_arg)

            for idx, var_obj in ipairs(node.VariableList) do
                local r = env:declare_local(var_obj)
                emit(env, "MOVE", r, call_reg + idx - 1)
                if var_obj.Captured then
                    emit(env, "MAKECELL", r, r)
                end
            end

            table.insert(env.break_targets, {})
            compile_Block(node.Body, env)

            emit(env, "JMP", 0, start_pc - #code - 1)

            local end_pc = #code + 1
            code[skip_jmp_idx][3] = end_pc - skip_jmp_idx - 1
            for _, break_pc in ipairs(table.remove(env.break_targets)) do
                code[break_pc][3] = end_pc - break_pc - 1
            end

            env:free_reg(_iter)
            env:free_reg(_state)
            env:free_reg(_var)

        elseif node.AstType == 'LabelStatement' then
            env.labels[node.Label] = #code + 1

        elseif node.AstType == 'GotoStatement' then
            local pc = emit(env, "JMP", 0, 0)
            table.insert(env.gotos, { label = node.Label, pc = pc })

        elseif node.AstType == 'BreakStatement' then
            local pc = emit(env, "JMP", 0, 0)
            if #env.break_targets > 0 then
                table.insert(env.break_targets[#env.break_targets], pc)
            end

        elseif node.AstType == 'ReturnStatement' then
            local regs = {}
            for _, val in ipairs(node.Arguments) do
                if val.AstType == 'CallExpr' or val.AstType == 'TableCallExpr' or val.AstType == 'StringCallExpr' or val.AstType == 'DotsExpr' then
                    local r = env:alloc_reg()
                    compile_expr(val, r, env, true)
                    table.insert(regs, { r, -1 })
                else
                    local r = env:alloc_reg()
                    compile_expr(val, r, env)
                    table.insert(regs, { r, 1 })
                end
            end

            if #regs == 0 then
                local r = env:alloc_reg()
                emit(env, "LOADNIL", r)
                emit(env, "RETURN", r, 1)
                env:free_reg(r)
            else
                local start_reg = regs[1][1]
                local num_rets = #regs
                if regs[#regs][2] == -1 then num_rets = -1 end
                emit(env, "RETURN", start_reg, num_rets)
                for _, info in ipairs(regs) do env:free_reg(info[1]) end
            end

        elseif node.AstType == 'Function' then
            local is_colon = false
            if node.Name and node.Name.AstType == 'MemberExpr' and node.Name.Indexer == ':' then
                is_colon = true
            end

            local sub_env = CompilerEnv.new(env, node.Scope)
            sub_env.is_vararg = node.VarArg

            local p_count = 0
            if is_colon then
                local self_var = node.Scope:CreateLocal("self")
                sub_env:declare_local(self_var)
                p_count = 1
            end

            for _, arg in ipairs(node.Arguments) do
                sub_env:declare_local(arg)
                p_count = p_count + 1
            end
            sub_env.num_params = p_count

            local use_B = compiler.use_storm and (not compiler.is_B) and math.random() < 0.4
            local opcodes_to_use = use_B and _G.OPCODES_B or _G.OPCODES_A
            local sub_compiler = compile_ast(opcodes_to_use, compiler.use_storm, compiler.global_protos, compiler.global_protos_B, use_B)

            local reg = env:alloc_reg()
            if use_B then
                local proto = sub_compiler:compile_function_body(node.Body, sub_env)
                local proto_idx = #compiler.global_protos_B
                table.insert(compiler.global_protos_B, proto)
                emit(env, "STORM", reg, proto_idx)
            else
                local proto = sub_compiler:compile_function_body(node.Body, sub_env)
                local proto_idx = #compiler.global_protos
                table.insert(compiler.global_protos, proto)
                emit(env, "CLOSURE", reg, proto_idx)
            end

            if node.IsLocal then
                local target_reg = env:declare_local(node.Name)
                emit(env, "MOVE", target_reg, reg)
                if node.Name.Captured then
                    emit(env, "MAKECELL", target_reg, target_reg)
                end
            else
                local target = node.Name
                if target.AstType == 'VarExpr' then
                    local res = env:resolve_var(target.Variable)
                    if not res or res.type == "global" then
                        local k = add_const(target.Name)
                        emit(env, "SETGLOBAL", reg, k)
                    elseif res.type == "local" then
                        if res.captured then
                            emit(env, "SETTABLE_1", reg, res.reg)
                        else
                            emit(env, "MOVE", res.reg, reg)
                        end
                    elseif res.type == "upval" then
                        emit(env, "SETUPVAL", reg, res.index)
                    end
                elseif target.AstType == 'MemberExpr' or target.AstType == 'IndexExpr' then
                    local t_reg = env:alloc_reg()
                    compile_expr(target.Base, t_reg, env)
                    local idx_reg = env:alloc_reg()
                    if target.AstType == 'MemberExpr' then
                        compile_expr({ AstType = 'StringExpr', Value = { Constant = target.Ident.Data } }, idx_reg, env)
                    else
                        compile_expr(target.Index, idx_reg, reg)
                    end
                    emit(env, "SETTABLE", t_reg, idx_reg, reg)
                    env:free_reg(t_reg)
                    env:free_reg(idx_reg)
                end
            end
            env:free_reg(reg)

        elseif node.AstType == 'CallStatement' then
            local r = env:alloc_reg()
            compile_expr(node.Expression, r, env)
            env:free_reg(r)
        end
    end

    function compile_expr(node, dest_reg, env, multi_ret)
        if node.AstType == 'Parentheses' then
            compile_expr(node.Inner, dest_reg, env, multi_ret)
        elseif node.AstType == 'NumberExpr' then
            emit(env, "LOADK", dest_reg, add_const(tonumber(node.Value.Data)))
        elseif node.AstType == 'StringExpr' then
            emit(env, "LOADK", dest_reg, add_const(node.Value.Constant))
        elseif node.AstType == 'NilExpr' then
            emit(env, "LOADNIL", dest_reg)
        elseif node.AstType == 'BooleanExpr' then
            emit(env, "LOADBOOL", dest_reg, node.Value and 1 or 0, 0)
        elseif node.AstType == 'DotsExpr' then
            emit(env, "VARARG", dest_reg, multi_ret and -1 or 1)
        elseif node.AstType == 'VarExpr' then
            local res = env:resolve_var(node.Variable)
            if not res or res.type == "global" then
                emit(env, "GETGLOBAL", dest_reg, add_const(node.Name))
            elseif res.type == "local" then
                if res.captured then
                    emit(env, "GETTABLE_1", dest_reg, res.reg)
                else
                    emit(env, "MOVE", dest_reg, res.reg)
                end
            elseif res.type == "upval" then
                emit(env, "GETUPVAL", dest_reg, res.index)
            end
        elseif node.AstType == 'BinopExpr' then
            if node.Op == 'and' then
                compile_expr(node.Lhs, dest_reg, env)
                emit(env, "TEST", dest_reg, 0)
                local skip_jmp_idx = #code + 1
                emit(env, "JMP", 0, 0)
                compile_expr(node.Rhs, dest_reg, env)
                local end_pc = #code + 1
                code[skip_jmp_idx][3] = end_pc - skip_jmp_idx - 1
            elseif node.Op == 'or' then
                compile_expr(node.Lhs, dest_reg, env)
                emit(env, "TEST", dest_reg, 1)
                local skip_jmp_idx = #code + 1
                emit(env, "JMP", 0, 0)
                compile_expr(node.Rhs, dest_reg, env)
                local end_pc = #code + 1
                code[skip_jmp_idx][3] = end_pc - skip_jmp_idx - 1
            else
                local op_map = {
                    ['+'] = "ADD", ['-'] = "SUB", ['*'] = "MUL", ['/'] = "DIV",
                    ['//'] = "IDIV", ['%'] = "MOD", ['^'] = "POW", ['&'] = "BAND",
                    ['|'] = "BOR", ['~'] = "BXOR", ['<<'] = "SHL", ['>>'] = "SHR",
                    ['..'] = "CONCAT"
                }
                local action = op_map[node.Op]
                if action then
                    compile_expr(node.Lhs, dest_reg, env)
                    local temp_reg = env:alloc_reg()
                    compile_expr(node.Rhs, temp_reg, env)
                    emit(env, action, dest_reg, dest_reg, temp_reg)
                    env:free_reg(temp_reg)
                else
                    local rel_map = {
                        ['=='] = "EQ", ['<'] = "LT", ['<='] = "LE"
                    }
                    action = rel_map[node.Op]
                    if action then
                        compile_expr(node.Lhs, dest_reg, env)
                        local temp_reg = env:alloc_reg()
                        compile_expr(node.Rhs, temp_reg, env)
                        emit(env, action, 0, dest_reg, temp_reg)
                        emit(env, "LOADBOOL", dest_reg, 0, 1)
                        emit(env, "LOADBOOL", dest_reg, 1, 0)
                        env:free_reg(temp_reg)
                    elseif node.Op == '>' then
                        compile_expr(node.Rhs, dest_reg, env)
                        local temp_reg = env:alloc_reg()
                        compile_expr(node.Lhs, temp_reg, env)
                        emit(env, "LT", 0, dest_reg, temp_reg)
                        emit(env, "LOADBOOL", dest_reg, 0, 1)
                        emit(env, "LOADBOOL", dest_reg, 1, 0)
                        env:free_reg(temp_reg)
                    elseif node.Op == '>=' then
                        compile_expr(node.Rhs, dest_reg, env)
                        local temp_reg = env:alloc_reg()
                        compile_expr(node.Lhs, temp_reg, env)
                        emit(env, "LE", 0, dest_reg, temp_reg)
                        emit(env, "LOADBOOL", dest_reg, 0, 1)
                        emit(env, "LOADBOOL", dest_reg, 1, 0)
                        env:free_reg(temp_reg)
                    elseif node.Op == '~=' then
                        compile_expr(node.Lhs, dest_reg, env)
                        local temp_reg = env:alloc_reg()
                        compile_expr(node.Rhs, temp_reg, env)
                        emit(env, "EQ", 1, dest_reg, temp_reg)
                        emit(env, "LOADBOOL", dest_reg, 0, 1)
                        emit(env, "LOADBOOL", dest_reg, 1, 0)
                        env:free_reg(temp_reg)
                    end
                end
            end

        elseif node.AstType == 'UnopExpr' then
            local op_map = {
                ['-'] = "UNM", ['~'] = "BNOT", ['not'] = "NOT", ['#'] = "LEN"
            }
            local action = op_map[node.Op]
            compile_expr(node.Rhs, dest_reg, env)
            emit(env, action, dest_reg, dest_reg)

        elseif node.AstType == 'IndexExpr' or node.AstType == 'MemberExpr' then
            local t_reg = env:alloc_reg()
            compile_expr(node.Base, t_reg, env)
            local idx_reg = env:alloc_reg()
            if node.AstType == 'MemberExpr' then
                compile_expr({ AstType = 'StringExpr', Value = { Constant = node.Ident.Data } }, idx_reg, env)
            else
                compile_expr(node.Index, idx_reg, env)
            end
            emit(env, "GETTABLE", dest_reg, t_reg, idx_reg)
            env:free_reg(t_reg)
            env:free_reg(idx_reg)

        elseif node.AstType == 'ConstructorExpr' then
            emit(env, "NEWTABLE", dest_reg, 0, 0)
            local pos_vals = {}
            for _, field in ipairs(node.EntryList) do
                if field.Type == 'Value' then
                    table.insert(pos_vals, field.Value)
                else
                    local k_idx
                    if field.Type == 'KeyString' then
                        k_idx = add_const(field.Key)
                        local val_reg = env:alloc_reg()
                        compile_expr(field.Value, val_reg, env)
                        emit(env, "SETTABLE_K", dest_reg, k_idx, val_reg)
                        env:free_reg(val_reg)
                    else
                        local key_reg = env:alloc_reg()
                        compile_expr(field.Key, key_reg, env)
                        local val_reg = env:alloc_reg()
                        compile_expr(field.Value, val_reg, env)
                        emit(env, "SETTABLE", dest_reg, key_reg, val_reg)
                        env:free_reg(key_reg)
                        env:free_reg(val_reg)
                    end
                end
            end
            for i, val in ipairs(pos_vals) do
                local key_reg = env:alloc_reg()
                compile_expr({ AstType = 'NumberExpr', Value = { Data = tostring(i) } }, key_reg, env)
                local val_reg = env:alloc_reg()
                compile_expr(val, val_reg, env)
                emit(env, "SETTABLE", dest_reg, key_reg, val_reg)
                env:free_reg(key_reg)
                env:free_reg(val_reg)
            end

        elseif node.AstType == 'Function' then
            local sub_env = CompilerEnv.new(env, node.Scope)
            sub_env.is_vararg = node.VarArg
            local p_count = 0
            for _, arg in ipairs(node.Arguments) do
                sub_env:declare_local(arg)
                p_count = p_count + 1
            end
            sub_env.num_params = p_count

            local use_B = compiler.use_storm and (not compiler.is_B) and math.random() < 0.4
            local opcodes_to_use = use_B and _G.OPCODES_B or _G.OPCODES_A
            local sub_compiler = compile_ast(opcodes_to_use, compiler.use_storm, compiler.global_protos, compiler.global_protos_B, use_B)

            if use_B then
                local proto = sub_compiler:compile_function_body(node.Body, sub_env)
                local proto_idx = #compiler.global_protos_B
                table.insert(compiler.global_protos_B, proto)
                emit(env, "STORM", dest_reg, proto_idx)
            else
                local proto = sub_compiler:compile_function_body(node.Body, sub_env)
                local proto_idx = #compiler.global_protos
                table.insert(compiler.global_protos, proto)
                emit(env, "CLOSURE", dest_reg, proto_idx)
            end

        elseif node.AstType == 'CallExpr' or node.AstType == 'StringCallExpr' or node.AstType == 'TableCallExpr' then
            local is_method = false
            local method_name
            local base_expr = node.Base
            if base_expr.AstType == 'MemberExpr' and base_expr.Indexer == ':' then
                is_method = true
                method_name = base_expr.Ident.Data
            end

            local func_reg = dest_reg

            if is_method then
                local temp_reg = func_reg + 1
                compile_expr(base_expr.Base, temp_reg, env)
                local k_idx = add_const(method_name)
                emit(env, "METHOD", func_reg, temp_reg, k_idx)

                local save_top = env.reg_top
                local args_count = #node.Arguments
                env.reg_top = func_reg + 2 + args_count

                local has_mult_ret_arg = false
                for idx, arg in ipairs(node.Arguments) do
                    local r = func_reg + 1 + idx
                    if arg.AstType == 'CallExpr' or arg.AstType == 'TableCallExpr' or arg.AstType == 'StringCallExpr' or arg.AstType == 'DotsExpr' then
                        compile_expr(arg, r, env, true)
                        if idx == args_count then has_mult_ret_arg = true end
                    else
                        compile_expr(arg, r, env)
                    end
                end

                env.reg_top = save_top
                local num_args = args_count + 1
                if has_mult_ret_arg then num_args = -1 end
                local num_rets = multi_ret and -1 or 1
                emit(env, "CALL", func_reg, num_args, num_rets)
            else
                compile_expr(node.Base, func_reg, env)

                local actual_args = node.Arguments
                if node.AstType == 'StringCallExpr' or node.AstType == 'TableCallExpr' then
                    actual_args = { node.Arguments[1] }
                end

                local save_top = env.reg_top
                local args_count = #actual_args
                env.reg_top = func_reg + 1 + args_count

                local has_mult_ret_arg = false
                for idx, arg in ipairs(actual_args) do
                    local r = func_reg + idx
                    if arg.AstType == 'CallExpr' or arg.AstType == 'TableCallExpr' or arg.AstType == 'StringCallExpr' or arg.AstType == 'DotsExpr' then
                        compile_expr(arg, r, env, true)
                        if idx == args_count then has_mult_ret_arg = true end
                    else
                        compile_expr(arg, r, env)
                    end
                end

                env.reg_top = save_top
                local num_args = args_count
                if has_mult_ret_arg then num_args = -1 end
                local num_rets = multi_ret and -1 or 1
                emit(env, "CALL", func_reg, num_args, num_rets)
            end
        end
    end

    function compiler.compile_function_body(self, block_node, env)
        compile_Block(block_node, env)

        for _, g in ipairs(env.gotos) do
            local label_name = g.label
            if env.labels[label_name] then
                local target_pc = env.labels[label_name]
                code[g.pc][3] = target_pc - g.pc - 1
            else
                code[g.pc][3] = 0
            end
        end

        if #code == 0 or code[#code][6] ~= "RETURN" then
            local r = env:alloc_reg()
            emit(env, "LOADNIL", r)
            emit(env, "RETURN", r, 1)
        end

        local up_descs = {}
        for _, up in ipairs(env.upvalues) do
            table.insert(up_descs, { type = up.type, index = up.index })
        end

        return {
            code = code,
            consts = consts,
            num_params = env.num_params,
            is_vararg = env.is_vararg,
            upvalues = up_descs,
            is_B = self.is_B
        }
    end

    return compiler
end

local function serialize_proto(proto, seed)
    local res = {}
    table.insert(res, string.pack("<BBB", proto.num_params, proto.is_vararg and 1 or 0, proto.is_B and 1 or 0))
    table.insert(res, string.pack("<I2", #proto.upvalues))
    for _, up in ipairs(proto.upvalues) do
        local t_val = (up.type == "local") and 0 or 1
        table.insert(res, string.pack("<BI2", t_val, up.index))
    end

    local const_count = 0
    for k in pairs(proto.consts) do
        if type(k) == "number" and k > const_count then
            const_count = k
        end
    end

    table.insert(res, string.pack("<I2", const_count))
    for c = 1, const_count do
        local const = proto.consts[c]
        if const == nil then
            table.insert(res, string.pack("<B", 0))
        elseif type(const) == "boolean" then
            table.insert(res, string.pack("<BB", 1, const and 1 or 0))
        elseif type(const) == "number" then
            if math.type and math.type(const) == "integer" then
                table.insert(res, string.pack("<Bi8", 4, const))
            else
                table.insert(res, string.pack("<Bd", 2, const))
            end
        elseif type(const) == "string" then
            local enc_bytes = {}
            for i = 1, #const do
                local b = string.byte(const, i)
                table.insert(enc_bytes, string.char((b ~ (seed + i - 1)) & 0xFF))
            end
            local enc_str = table.concat(enc_bytes)
            table.insert(res, string.pack("<BI2", 3, #enc_str) .. enc_str)
        end
    end

    table.insert(res, string.pack("<I4", #proto.code))
    for _, inst in ipairs(proto.code) do
        table.insert(res, string.pack("<iiiii", inst[1], inst[2], inst[3], inst[4], inst[5]))
    end

    return table.concat(res)
end

local function serialize_proto_list(protos, seed)
    local res = {}
    table.insert(res, string.pack("<I2", #protos))
    for _, proto in ipairs(protos) do
        local p_bytes = serialize_proto(proto, seed)
        table.insert(res, string.pack("<I4", #p_bytes) .. p_bytes)
    end
    return table.concat(res)
end

local function generate_lua_runner(seed, opcodes_A, opcodes_B, anti_debug)
    -- Map all standard internal variables to randomized numeric-like hex identifiers
    local names = {
        _0x_i = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_j = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_u = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_num_vals = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_ENV = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_run_vm_A = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_run_vm_B = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_create_closure_A = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_create_closure_B = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_protos = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_protos_B = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_dbg_lib = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_unpack_proto_list = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_instrs = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_consts = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_pc = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_regs = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_num_params = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_is_vararg = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_args = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_vararg_list = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_inst = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_op = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_a = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_b = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_c = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_expected_hash = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_results = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_num_returns = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_success = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_args_to_call = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_num_args = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_func = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_rets = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_num_rets = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_data = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_seed = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_pr = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_num_protos = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_pos = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_p_len = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_p_data = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_proto = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_is_B_val = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_up_count = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_up_pos = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_t_val = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_idx = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_idx_val = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_const_count = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_c_type = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_b_val = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_n_val = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_s_len = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_s_bytes = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_dec = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_inst_count = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_computed_hash = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_success_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_debug_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_ok_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_f_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_i_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_name_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_val_init = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_upvals = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_up_desc = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_child_proto = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_child_upvals = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_cond = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_expected = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_x_dbg = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
        _0x_y_dbg = "_0x" .. string.format("%08x", math.random(0, 0xFFFFFFFF)),
    }

    local rand_ops = {
        "(math.abs(math.sin({_0x_pc})) <= 1.0001)",
        "(math.cos({_0x_pc})*math.cos({_0x_pc}) + math.sin({_0x_pc})*math.sin({_0x_pc}) >= 0.999)",
        "(math.floor(math.abs(math.sin({_0x_pc} + 1))) >= 0)",
        "(math.abs(math.sin({_0x_pc})) * math.abs(math.cos({_0x_pc})) <= 0.5001)",
        "({_0x_pc} % 2 == 0 or {_0x_pc} % 2 ~= 0)"
    }
    local function rand_opaque_predicate()
        return rand_ops[math.random(1, #rand_ops)]
    end

    local template = [=[-- High-strength AST-based VM Obfuscation output
local {_0x_ENV} = (function()
    local {_0x_success_init}, {_0x_debug_init} = pcall(require, "debug")
    if {_0x_success_init} and {_0x_debug_init} and {_0x_debug_init}.getinfo then
        local {_0x_ok_init}, {_0x_f_init} = pcall({_0x_debug_init}.getinfo, 2, "f")
        if {_0x_ok_init} and {_0x_f_init} and {_0x_f_init}.func then
            local {_0x_i_init} = 1
            while true do
                local {_0x_name_init}, {_0x_val_init} = {_0x_debug_init}.getupvalue({_0x_f_init}.func, {_0x_i_init})
                if not {_0x_name_init} then break end
                if {_0x_name_init} == "_ENV" then return {_0x_val_init} end
                {_0x_i_init} = {_0x_i_init} + 1
            end
        end
    end
    return _ENV or _G
end)()

local {_0x_run_vm_A}, {_0x_run_vm_B}
local {_0x_create_closure_A}, {_0x_create_closure_B}
local {_0x_protos}, {_0x_protos_B}
local {_0x_dbg_lib} = (function()
    local {_0x_success_init}, {_0x_debug_init} = pcall(require, "debug")
    if {_0x_success_init} and {_0x_debug_init} then return {_0x_debug_init} end
    return {_0x_ENV} and {_0x_ENV}.debug
end)()

local function {_0x_unpack_proto_list}({_0x_data}, {_0x_seed})
    local {_0x_pr} = {}
    local {_0x_num_protos}, {_0x_pos} = string.unpack("<I2", {_0x_data})
    for {_0x_idx} = 1, {_0x_num_protos} do
        local {_0x_p_len}
        {_0x_p_len}, {_0x_pos} = string.unpack("<I4", {_0x_data}, {_0x_pos})
        local {_0x_p_data} = string.sub({_0x_data}, {_0x_pos}, {_0x_pos} + {_0x_p_len} - 1)
        {_0x_pos} = {_0x_pos} + {_0x_p_len}

        local {_0x_proto} = { upvalues = {}, consts = {}, code = {} }
        local {_0x_num_params}, {_0x_is_vararg}, {_0x_is_B_val}, {_0x_up_count}, {_0x_up_pos} = string.unpack("<BBBI2", {_0x_p_data})
        {_0x_proto}.num_params = {_0x_num_params}
        {_0x_proto}.is_vararg = ({_0x_is_vararg} ~= 0)
        {_0x_proto}.is_B = ({_0x_is_B_val} ~= 0)

        for {_0x_u} = 1, {_0x_up_count} do
            local {_0x_t_val}, {_0x_idx_val}
            {_0x_t_val}, {_0x_idx_val}, {_0x_up_pos} = string.unpack("<BI2", {_0x_p_data}, {_0x_up_pos})
            table.insert({_0x_proto}.upvalues, {
                type = ({_0x_t_val} == 0) and "local" or "upval",
                index = {_0x_idx_val}
            })
        end

        local {_0x_const_count}
        {_0x_const_count}, {_0x_up_pos} = string.unpack("<I2", {_0x_p_data}, {_0x_up_pos})
        for {_0x_c} = 1, {_0x_const_count} do
            local {_0x_c_type}
            {_0x_c_type}, {_0x_up_pos} = string.unpack("<B", {_0x_p_data}, {_0x_up_pos})
            if {_0x_c_type} == 0 then
                {_0x_proto}.consts[{_0x_c}] = nil
            elseif {_0x_c_type} == 1 then
                local {_0x_b_val}
                {_0x_b_val}, {_0x_up_pos} = string.unpack("<B", {_0x_p_data}, {_0x_up_pos})
                {_0x_proto}.consts[{_0x_c}] = ({_0x_b_val} ~= 0)
            elseif {_0x_c_type} == 2 then
                local {_0x_n_val}
                {_0x_n_val}, {_0x_up_pos} = string.unpack("<d", {_0x_p_data}, {_0x_up_pos})
                {_0x_proto}.consts[{_0x_c}] = {_0x_n_val}
            elseif {_0x_c_type} == 4 then
                local {_0x_n_val}
                {_0x_n_val}, {_0x_up_pos} = string.unpack("<i8", {_0x_p_data}, {_0x_up_pos})
                {_0x_proto}.consts[{_0x_c}] = {_0x_n_val}
            elseif {_0x_c_type} == 3 then
                local {_0x_s_len}
                {_0x_s_len}, {_0x_up_pos} = string.unpack("<I2", {_0x_p_data}, {_0x_up_pos})
                local {_0x_s_bytes} = string.sub({_0x_p_data}, {_0x_up_pos}, {_0x_up_pos} + {_0x_s_len} - 1)
                {_0x_up_pos} = {_0x_up_pos} + {_0x_s_len}

                local {_0x_dec} = {}
                for {_0x_idx_val} = 1, #{_0x_s_bytes} do
                    local {_0x_b} = string.byte({_0x_s_bytes}, {_0x_idx_val})
                    {_0x_dec}[{_0x_idx_val}] = string.char(({_0x_b} ~ ({_0x_seed} + {_0x_idx_val} - 1)) & 0xFF)
                end
                {_0x_proto}.consts[{_0x_c}] = table.concat({_0x_dec})
            end
        end

        local {_0x_inst_count}
        {_0x_inst_count}, {_0x_up_pos} = string.unpack("<I4", {_0x_p_data}, {_0x_up_pos})
        for {_0x_j} = 1, {_0x_inst_count} do
            local {_0x_op}, {_0x_a}, {_0x_b}, {_0x_c}, {_0x_expected_hash}
            {_0x_op}, {_0x_a}, {_0x_b}, {_0x_c}, {_0x_expected_hash}, {_0x_up_pos} = string.unpack("<iiiii", {_0x_p_data}, {_0x_up_pos})
            table.insert({_0x_proto}.code, { {_0x_op}, {_0x_a}, {_0x_b}, {_0x_c}, {_0x_expected_hash} })
        end

        table.insert({_0x_pr}, {_0x_proto})
    end
    return {_0x_pr}
end

{_0x_create_closure_A} = function({_0x_proto}, {_0x_upvals})
    return function(...)
        return {_0x_run_vm_A}({_0x_proto}, {_0x_upvals}, ...)
    end
end

{_0x_create_closure_B} = function({_0x_proto}, {_0x_upvals})
    return function(...)
        return {_0x_run_vm_B}({_0x_proto}, {_0x_upvals}, ...)
    end
end

{_0x_run_vm_A} = function({_0x_proto}, {_0x_upvals}, ...)
    local {_0x_instrs} = {_0x_proto}.code
    local {_0x_consts} = {_0x_proto}.consts
    local {_0x_pc} = 1
    local {_0x_regs} = {}
    local {_0x_num_params} = {_0x_proto}.num_params
    local {_0x_is_vararg} = {_0x_proto}.is_vararg

    local {_0x_args} = { ... }
    for {_0x_i} = 1, {_0x_num_params} do
        {_0x_regs}[{_0x_i} - 1] = {_0x_args}[{_0x_i}]
    end
    local {_0x_vararg_list} = {}
    if {_0x_is_vararg} then
        for {_0x_i} = {_0x_num_params} + 1, #{_0x_args} do
            table.insert({_0x_vararg_list}, {_0x_args}[{_0x_i}])
        end
    end

    while true do
        local {_0x_inst} = {_0x_instrs}[{_0x_pc}]
        if not {_0x_inst} then break end
        local {_0x_op} = {_0x_inst}[1]
        local {_0x_a} = {_0x_inst}[2]
        local {_0x_b} = {_0x_inst}[3]
        local {_0x_c} = {_0x_inst}[4]
        local {_0x_expected_hash} = {_0x_inst}[5]
        {_0x_pc} = {_0x_pc} + 1

        if {_0x_op} == ]=] .. opcodes_A["JMP"] .. [=[ or {_0x_op} == ]=] .. opcodes_A["CALL"] .. [=[ then
            local {_0x_computed_hash} = (({_0x_pc} - 1) * 31 + {_0x_op} * 17) % 10000007
            if {_0x_computed_hash} ~= {_0x_expected_hash} then
                error("Integrity check failure: VM bytecode mismatch")
            end
        end
]=]

    if anti_debug then
        template = template .. [=[        do
            if {_0x_dbg_lib} and {_0x_dbg_lib}.gethook and {_0x_dbg_lib}.gethook() then
                local {_0x_x_dbg} = nil
                local {_0x_y_dbg} = {_0x_x_dbg}.invalid_field_access
            end
        end
]=]
    end

    template = template .. "        if " .. rand_opaque_predicate() .. " then\n        else\n            {_0x_pc} = {_0x_pc} + 99999\n        end\n\n"

    template = template .. [=[        if {_0x_op} == ]=] .. opcodes_A["MOVE"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_A["LOADK"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_consts}[{_0x_b} + 1]
        elseif {_0x_op} == ]=] .. opcodes_A["LOADNIL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = nil
        elseif {_0x_op} == ]=] .. opcodes_A["LOADBOOL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = ({_0x_b} ~= 0)
            if {_0x_c} ~= 0 then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_A["GETUPVAL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_upvals}[{_0x_b} + 1][1]
        elseif {_0x_op} == ]=] .. opcodes_A["SETUPVAL"] .. [=[ then
            {_0x_upvals}[{_0x_b} + 1][1] = {_0x_regs}[{_0x_a}]
        elseif {_0x_op} == ]=] .. opcodes_A["GETGLOBAL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_ENV}[{_0x_consts}[{_0x_b} + 1]]
        elseif {_0x_op} == ]=] .. opcodes_A["SETGLOBAL"] .. [=[ then
            {_0x_ENV}[{_0x_consts}[{_0x_b} + 1]] = {_0x_regs}[{_0x_a}]
        elseif {_0x_op} == ]=] .. opcodes_A["GETTABLE"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}][{_0x_regs}[{_0x_c}]]
        elseif {_0x_op} == ]=] .. opcodes_A["SETTABLE"] .. [=[ then
            {_0x_regs}[{_0x_a}][{_0x_regs}[{_0x_b}]] = {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["SETTABLE_K"] .. [=[ then
            {_0x_regs}[{_0x_a}][{_0x_consts}[{_0x_b} + 1]] = {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["NEWTABLE"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {}
        elseif {_0x_op} == ]=] .. opcodes_A["METHOD"] .. [=[ then
            {_0x_regs}[{_0x_a} + 1] = {_0x_regs}[{_0x_b}]
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}][{_0x_consts}[{_0x_c} + 1]]
        elseif {_0x_op} == ]=] .. opcodes_A["ADD"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] + {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["SUB"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] - {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["MUL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] * {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["DIV"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] / {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["IDIV"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] // {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["MOD"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] % {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["POW"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] ^ {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["BAND"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] & {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["BOR"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] | {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["BXOR"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] ~ {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["SHL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] << {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["SHR"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] >> {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_A["UNM"] .. [=[ then
            {_0x_regs}[{_0x_a}] = -{_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_A["BNOT"] .. [=[ then
            {_0x_regs}[{_0x_a}] = ~{_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_A["LEN"] .. [=[ then
            {_0x_regs}[{_0x_a}] = #{_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_A["NOT"] .. [=[ then
            {_0x_regs}[{_0x_a}] = not {_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_A["JMP"] .. [=[ then
            {_0x_pc} = {_0x_pc} + {_0x_b}
        elseif {_0x_op} == ]=] .. opcodes_A["EQ"] .. [=[ then
            if ({_0x_regs}[{_0x_b}] == {_0x_regs}[{_0x_c}]) ~= ({_0x_a} ~= 0) then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_A["LT"] .. [=[ then
            if ({_0x_regs}[{_0x_b}] < {_0x_regs}[{_0x_c}]) ~= ({_0x_a} ~= 0) then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_A["LE"] .. [=[ then
            if ({_0x_regs}[{_0x_b}] <= {_0x_regs}[{_0x_c}]) ~= ({_0x_a} ~= 0) then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_A["TEST"] .. [=[ then
            local {_0x_cond} = not not {_0x_regs}[{_0x_a}]
            local {_0x_expected} = ({_0x_b} ~= 0)
            if {_0x_cond} ~= {_0x_expected} then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_A["CALL"] .. [=[ then
            local {_0x_args_to_call} = {}
            local {_0x_num_args} = {_0x_b}
            if {_0x_num_args} == -1 then
                {_0x_num_args} = 0
                while {_0x_regs}[{_0x_a} + 1 + {_0x_num_args}] ~= nil do
                    {_0x_num_args} = {_0x_num_args} + 1
                end
            end
            for {_0x_i} = 1, {_0x_num_args} do
                {_0x_args_to_call}[{_0x_i}] = {_0x_regs}[{_0x_a} + {_0x_i}]
            end
            local {_0x_func} = {_0x_regs}[{_0x_a}]
            if {_0x_func} == {_0x_ENV}.coroutine.yield or {_0x_func} == {_0x_ENV}.coroutine.resume then
                local {_0x_results} = { {_0x_func}(table.unpack({_0x_args_to_call}, 1, {_0x_num_args})) }
                local {_0x_num_returns} = {_0x_c}
                if {_0x_num_returns} == -1 then
                    {_0x_num_returns} = #{_0x_results}
                end
                for {_0x_i} = 1, {_0x_num_returns} do
                    {_0x_regs}[{_0x_a} + {_0x_i} - 1] = {_0x_results}[{_0x_i}]
                end
                for {_0x_i} = {_0x_num_returns} + 1, {_0x_num_returns} + 50 do
                    {_0x_regs}[{_0x_a} + {_0x_i} - 1] = nil
                end
            else
                local {_0x_results} = { pcall({_0x_func}, table.unpack({_0x_args_to_call}, 1, {_0x_num_args})) }
                local {_0x_success} = {_0x_results}[1]
                if not {_0x_success} then
                    error({_0x_results}[2], 0)
                else
                    local {_0x_num_returns} = {_0x_c}
                    if {_0x_num_returns} == -1 then
                        {_0x_num_returns} = #{_0x_results} - 1
                    end
                    for {_0x_i} = 1, {_0x_num_returns} do
                        {_0x_regs}[{_0x_a} + {_0x_i} - 1] = {_0x_results}[{_0x_i} + 1]
                    end
                    for {_0x_i} = {_0x_num_returns} + 1, {_0x_num_returns} + 50 do
                        {_0x_regs}[{_0x_a} + {_0x_i} - 1] = nil
                    end
                end
            end
        elseif {_0x_op} == ]=] .. opcodes_A["RETURN"] .. [=[ then
            local {_0x_rets} = {}
            local {_0x_num_rets} = {_0x_b}
            if {_0x_num_rets} == -1 then
                {_0x_num_rets} = 0
                while {_0x_regs}[{_0x_a} + {_0x_num_rets}] ~= nil do
                    {_0x_num_rets} = {_0x_num_rets} + 1
                end
            end
            for {_0x_i} = 1, {_0x_num_rets} do
                {_0x_rets}[{_0x_i}] = {_0x_regs}[{_0x_a} + {_0x_i} - 1]
            end
            return table.unpack({_0x_rets}, 1, {_0x_num_rets})
        elseif {_0x_op} == ]=] .. opcodes_A["VARARG"] .. [=[ then
            local {_0x_num_vals} = {_0x_b}
            if {_0x_num_vals} == -1 then
                {_0x_num_vals} = #{_0x_vararg_list}
            end
            for {_0x_i} = 1, {_0x_num_vals} do
                {_0x_regs}[{_0x_a} + {_0x_i} - 1] = {_0x_vararg_list}[{_0x_i}]
            end
        elseif {_0x_op} == ]=] .. opcodes_A["CLOSURE"] .. [=[ or {_0x_op} == ]=] .. opcodes_A["STORM"] .. [=[ then
            local {_0x_child_proto}
            if {_0x_op} == ]=] .. opcodes_A["STORM"] .. [=[ then
                {_0x_child_proto} = {_0x_protos_B}[{_0x_b} + 1]
            else
                {_0x_child_proto} = {_0x_protos}[{_0x_b} + 1]
            end
            local {_0x_child_upvals} = {}
            for {_0x_idx_val}, {_0x_up_desc} in ipairs({_0x_child_proto}.upvalues) do
                if {_0x_up_desc}.type == "local" then
                    {_0x_child_upvals}[{_0x_idx_val}] = {_0x_regs}[{_0x_up_desc}.index]
                elseif {_0x_up_desc}.type == "upval" then
                    {_0x_child_upvals}[{_0x_idx_val}] = {_0x_upvals}[{_0x_up_desc}.index + 1]
                end
            end
            if {_0x_child_proto}.is_B then
                {_0x_regs}[{_0x_a}] = {_0x_create_closure_B}({_0x_child_proto}, {_0x_child_upvals})
            else
                {_0x_regs}[{_0x_a}] = {_0x_create_closure_A}({_0x_child_proto}, {_0x_child_upvals})
            end
        elseif {_0x_op} == ]=] .. opcodes_A["MAKECELL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = { {_0x_regs}[{_0x_b}] }
        elseif {_0x_op} == ]=] .. opcodes_A["GETTABLE_1"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}][1]
        elseif {_0x_op} == ]=] .. opcodes_A["SETTABLE_1"] .. [=[ then
            {_0x_regs}[{_0x_b}][1] = {_0x_regs}[{_0x_a}]
        elseif {_0x_op} == ]=] .. opcodes_A["CONCAT"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] .. {_0x_regs}[{_0x_c}]
        end
    end
end

{_0x_run_vm_B} = function({_0x_proto}, {_0x_upvals}, ...)
    local {_0x_instrs} = {_0x_proto}.code
    local {_0x_consts} = {_0x_proto}.consts
    local {_0x_pc} = 1
    local {_0x_regs} = {}
    local {_0x_num_params} = {_0x_proto}.num_params
    local {_0x_is_vararg} = {_0x_proto}.is_vararg

    local {_0x_args} = { ... }
    for {_0x_i} = 1, {_0x_num_params} do
        {_0x_regs}[{_0x_i} - 1] = {_0x_args}[{_0x_i}]
    end
    local {_0x_vararg_list} = {}
    if {_0x_is_vararg} then
        for {_0x_i} = {_0x_num_params} + 1, #{_0x_args} do
            table.insert({_0x_vararg_list}, {_0x_args}[{_0x_i}])
        end
    end

    while true do
        local {_0x_inst} = {_0x_instrs}[{_0x_pc}]
        if not {_0x_inst} then break end
        local {_0x_op} = {_0x_inst}[1]
        local {_0x_a} = {_0x_inst}[2]
        local {_0x_b} = {_0x_inst}[3]
        local {_0x_c} = {_0x_inst}[4]
        local {_0x_expected_hash} = {_0x_inst}[5]
        {_0x_pc} = {_0x_pc} + 1

        if {_0x_op} == ]=] .. opcodes_B["JMP"] .. [=[ or {_0x_op} == ]=] .. opcodes_B["CALL"] .. [=[ then
            local {_0x_computed_hash} = (({_0x_pc} - 1) * 31 + {_0x_op} * 17) % 10000007
            if {_0x_computed_hash} ~= {_0x_expected_hash} then
                error("Integrity check failure: VM bytecode mismatch")
            end
        end
]=]

    if anti_debug then
        template = template .. [=[        do
            if {_0x_dbg_lib} and {_0x_dbg_lib}.gethook and {_0x_dbg_lib}.gethook() then
                local {_0x_x_dbg} = nil
                local {_0x_y_dbg} = {_0x_x_dbg}.invalid_field_access
            end
        end
]=]
    end

    template = template .. [=[        if {_0x_op} == ]=] .. opcodes_B["MOVE"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_B["LOADK"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_consts}[{_0x_b} + 1]
        elseif {_0x_op} == ]=] .. opcodes_B["LOADNIL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = nil
        elseif {_0x_op} == ]=] .. opcodes_B["LOADBOOL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = ({_0x_b} ~= 0)
            if {_0x_c} ~= 0 then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_B["GETUPVAL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_upvals}[{_0x_b} + 1][1]
        elseif {_0x_op} == ]=] .. opcodes_B["SETUPVAL"] .. [=[ then
            {_0x_upvals}[{_0x_b} + 1][1] = {_0x_regs}[{_0x_a}]
        elseif {_0x_op} == ]=] .. opcodes_B["GETGLOBAL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_ENV}[{_0x_consts}[{_0x_b} + 1]]
        elseif {_0x_op} == ]=] .. opcodes_B["SETGLOBAL"] .. [=[ then
            {_0x_ENV}[{_0x_consts}[{_0x_b} + 1]] = {_0x_regs}[{_0x_a}]
        elseif {_0x_op} == ]=] .. opcodes_B["GETTABLE"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}][{_0x_regs}[{_0x_c}]]
        elseif {_0x_op} == ]=] .. opcodes_B["SETTABLE"] .. [=[ then
            {_0x_regs}[{_0x_a}][{_0x_regs}[{_0x_b}]] = {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["SETTABLE_K"] .. [=[ then
            {_0x_regs}[{_0x_a}][{_0x_consts}[{_0x_b} + 1]] = {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["NEWTABLE"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {}
        elseif {_0x_op} == ]=] .. opcodes_B["METHOD"] .. [=[ then
            {_0x_regs}[{_0x_a} + 1] = {_0x_regs}[{_0x_b}]
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}][{_0x_consts}[{_0x_c} + 1]]
        elseif {_0x_op} == ]=] .. opcodes_B["ADD"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] + {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["SUB"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] - {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["MUL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] * {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["DIV"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] / {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["IDIV"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] // {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["MOD"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] % {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["POW"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] ^ {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["BAND"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] & {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["BOR"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] | {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["BXOR"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] ~ {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["SHL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] << {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["SHR"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] >> {_0x_regs}[{_0x_c}]
        elseif {_0x_op} == ]=] .. opcodes_B["UNM"] .. [=[ then
            {_0x_regs}[{_0x_a}] = -{_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_B["BNOT"] .. [=[ then
            {_0x_regs}[{_0x_a}] = ~{_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_B["LEN"] .. [=[ then
            {_0x_regs}[{_0x_a}] = #{_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_B["NOT"] .. [=[ then
            {_0x_regs}[{_0x_a}] = not {_0x_regs}[{_0x_b}]
        elseif {_0x_op} == ]=] .. opcodes_B["JMP"] .. [=[ then
            {_0x_pc} = {_0x_pc} + {_0x_b}
        elseif {_0x_op} == ]=] .. opcodes_B["EQ"] .. [=[ then
            if ({_0x_regs}[{_0x_b}] == {_0x_regs}[{_0x_c}]) ~= ({_0x_a} ~= 0) then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_B["LT"] .. [=[ then
            if ({_0x_regs}[{_0x_b}] < {_0x_regs}[{_0x_c}]) ~= ({_0x_a} ~= 0) then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_B["LE"] .. [=[ then
            if ({_0x_regs}[{_0x_b}] <= {_0x_regs}[{_0x_c}]) ~= ({_0x_a} ~= 0) then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_B["TEST"] .. [=[ then
            local {_0x_cond} = not not {_0x_regs}[{_0x_a}]
            local {_0x_expected} = ({_0x_b} ~= 0)
            if {_0x_cond} ~= {_0x_expected} then {_0x_pc} = {_0x_pc} + 1 end
        elseif {_0x_op} == ]=] .. opcodes_B["CALL"] .. [=[ then
            local {_0x_args_to_call} = {}
            local {_0x_num_args} = {_0x_b}
            if {_0x_num_args} == -1 then
                {_0x_num_args} = 0
                while {_0x_regs}[{_0x_a} + 1 + {_0x_num_args}] ~= nil do
                    {_0x_num_args} = {_0x_num_args} + 1
                end
            end
            for {_0x_i} = 1, {_0x_num_args} do
                {_0x_args_to_call}[{_0x_i}] = {_0x_regs}[{_0x_a} + {_0x_i}]
            end
            local {_0x_func} = {_0x_regs}[{_0x_a}]
            if {_0x_func} == {_0x_ENV}.coroutine.yield or {_0x_func} == {_0x_ENV}.coroutine.resume then
                local {_0x_results} = { {_0x_func}(table.unpack({_0x_args_to_call}, 1, {_0x_num_args})) }
                local {_0x_num_returns} = {_0x_c}
                if {_0x_num_returns} == -1 then
                    {_0x_num_returns} = #{_0x_results}
                end
                for {_0x_i} = 1, {_0x_num_returns} do
                    {_0x_regs}[{_0x_a} + {_0x_i} - 1] = {_0x_results}[{_0x_i}]
                end
                for {_0x_i} = {_0x_num_returns} + 1, {_0x_num_returns} + 50 do
                    {_0x_regs}[{_0x_a} + {_0x_i} - 1] = nil
                end
            else
                local {_0x_results} = { pcall({_0x_func}, table.unpack({_0x_args_to_call}, 1, {_0x_num_args})) }
                local {_0x_success} = {_0x_results}[1]
                if not {_0x_success} then
                    error({_0x_results}[2], 0)
                else
                    local {_0x_num_returns} = {_0x_c}
                    if {_0x_num_returns} == -1 then
                        {_0x_num_returns} = #{_0x_results} - 1
                    end
                    for {_0x_i} = 1, {_0x_num_returns} do
                        {_0x_regs}[{_0x_a} + {_0x_i} - 1] = {_0x_results}[{_0x_i} + 1]
                    end
                    for {_0x_i} = {_0x_num_returns} + 1, {_0x_num_returns} + 50 do
                        {_0x_regs}[{_0x_a} + {_0x_i} - 1] = nil
                    end
                end
            end
        elseif {_0x_op} == ]=] .. opcodes_B["RETURN"] .. [=[ then
            local {_0x_rets} = {}
            local {_0x_num_rets} = {_0x_b}
            if {_0x_num_rets} == -1 then
                {_0x_num_rets} = 0
                while {_0x_regs}[{_0x_a} + {_0x_num_rets}] ~= nil do
                    {_0x_num_rets} = {_0x_num_rets} + 1
                end
            end
            for {_0x_i} = 1, {_0x_num_rets} do
                {_0x_rets}[{_0x_i}] = {_0x_regs}[{_0x_a} + {_0x_i} - 1]
            end
            return table.unpack({_0x_rets}, 1, {_0x_num_rets})
        elseif {_0x_op} == ]=] .. opcodes_B["VARARG"] .. [=[ then
            local {_0x_num_vals} = {_0x_b}
            if {_0x_num_vals} == -1 then
                {_0x_num_vals} = #{_0x_vararg_list}
            end
            for {_0x_i} = 1, {_0x_num_vals} do
                {_0x_regs}[{_0x_a} + {_0x_i} - 1] = {_0x_vararg_list}[{_0x_i}]
            end
        elseif {_0x_op} == ]=] .. opcodes_B["CLOSURE"] .. [=[ or {_0x_op} == ]=] .. opcodes_B["STORM"] .. [=[ then
            local {_0x_child_proto}
            if {_0x_op} == ]=] .. opcodes_B["STORM"] .. [=[ then
                {_0x_child_proto} = {_0x_protos_B}[{_0x_b} + 1]
            else
                {_0x_child_proto} = {_0x_protos}[{_0x_b} + 1]
            end
            local {_0x_child_upvals} = {}
            for {_0x_idx_val}, {_0x_up_desc} in ipairs({_0x_child_proto}.upvalues) do
                if {_0x_up_desc}.type == "local" then
                    {_0x_child_upvals}[{_0x_idx_val}] = {_0x_regs}[{_0x_up_desc}.index]
                elseif {_0x_up_desc}.type == "upval" then
                    {_0x_child_upvals}[{_0x_idx_val}] = {_0x_upvals}[{_0x_up_desc}.index + 1]
                end
            end
            if {_0x_child_proto}.is_B then
                {_0x_regs}[{_0x_a}] = {_0x_create_closure_B}({_0x_child_proto}, {_0x_child_upvals})
            else
                {_0x_regs}[{_0x_a}] = {_0x_create_closure_A}({_0x_child_proto}, {_0x_child_upvals})
            end
        elseif {_0x_op} == ]=] .. opcodes_B["MAKECELL"] .. [=[ then
            {_0x_regs}[{_0x_a}] = { {_0x_regs}[{_0x_b}] }
        elseif {_0x_op} == ]=] .. opcodes_B["GETTABLE_1"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}][1]
        elseif {_0x_op} == ]=] .. opcodes_B["SETTABLE_1"] .. [=[ then
            {_0x_regs}[{_0x_b}][1] = {_0x_regs}[{_0x_a}]
        elseif {_0x_op} == ]=] .. opcodes_B["CONCAT"] .. [=[ then
            {_0x_regs}[{_0x_a}] = {_0x_regs}[{_0x_b}] .. {_0x_regs}[{_0x_c}]
        end
    end
end
]=]

    -- Apply the randomized names to the template
    for k, v in pairs(names) do
        template = template:gsub("{" .. k .. "}", v)
    end

    return template, names
end

local VM_ACTIONS = {
    "MOVE", "LOADK", "LOADNIL", "LOADBOOL", "GETUPVAL", "SETUPVAL",
    "GETGLOBAL", "SETGLOBAL", "GETTABLE", "SETTABLE", "SETTABLE_K", "NEWTABLE",
    "METHOD", "ADD", "SUB", "MUL", "DIV", "IDIV", "MOD", "POW",
    "BAND", "BOR", "BXOR", "SHL", "SHR", "UNM", "BNOT", "LEN",
    "NOT", "JMP", "EQ", "LT", "LE", "TEST", "CALL", "RETURN",
    "VARARG", "CLOSURE", "STORM", "MAKECELL", "GETTABLE_1", "SETTABLE_1", "CONCAT"
}

local function generate_random_opcodes()
    local opcodes = {}
    local used = {}
    for _, act in ipairs(VM_ACTIONS) do
        while true do
            local op = math.random(10, 999)
            if not used[op] then
                used[op] = true
                opcodes[act] = op
                break
            end
        end
    end
    return opcodes
end

_G.ParseLua = ParseLua
_G.mark_captured_variables = mark_captured_variables
_G.compile_ast = compile_ast
_G.CompilerEnv = CompilerEnv
_G.VM_ACTIONS = VM_ACTIONS

_G.obfuscate = function(source_code, anti_debug, depth)
    depth = depth or 0
    if anti_debug == nil then anti_debug = true end
    if source_code:find("@antiDebug false") then
        anti_debug = false
    end

    math.randomseed(os.time())

    local st, tree = ParseLua(source_code)
    if not st then error("Parser Error: " .. tostring(tree)) end

    mark_captured_variables(tree, tree.Scope)

    tree = apply_mba(tree)

    _G.OPCODES_A = generate_random_opcodes()
    _G.OPCODES_B = generate_random_opcodes()

    local global_protos_A = {}
    local global_protos_B = {}
    local compiler = compile_ast(_G.OPCODES_A, true, global_protos_A, global_protos_B, false)

    local main_proto = compiler:compile_function_body(tree, CompilerEnv.new(nil, tree.Scope))
    table.insert(global_protos_A, main_proto)

    local seed = math.random(100, 50000)
    local serialized_A = serialize_proto_list(global_protos_A, seed)
    local serialized_B = serialize_proto_list(global_protos_B, seed)

    local escaped_A = {}
    for i = 1, #serialized_A do
        table.insert(escaped_A, string.format("\\%d", string.byte(serialized_A, i)))
    end
    local escaped_B = {}
    for i = 1, #serialized_B do
        table.insert(escaped_B, string.format("\\%d", string.byte(serialized_B, i)))
    end

    local runner_code, names = generate_lua_runner(seed, _G.OPCODES_A, _G.OPCODES_B, anti_debug)

    -- Retrieve the randomized run_vm_A and protos variable names directly from names map
    local run_vm_A_name = names._0x_run_vm_A
    local protos_name = names._0x_protos
    local protos_B_name = names._0x_protos_B
    local unpack_proto_list_name = names._0x_unpack_proto_list

    local wrapper_code = "return function(vm_a_data, vm_b_data, seed)\n" ..
        "    local " .. run_vm_A_name .. ", " .. names._0x_run_vm_B .. "\n" ..
        "    local " .. names._0x_create_closure_A .. ", " .. names._0x_create_closure_B .. "\n" ..
        "    local " .. protos_name .. ", " .. protos_B_name .. "\n\n" ..
        runner_code .. "\n\n" ..
        "    " .. protos_name .. " = " .. unpack_proto_list_name .. "(vm_a_data, seed)\n" ..
        "    " .. protos_B_name .. " = " .. unpack_proto_list_name .. "(vm_b_data, seed)\n\n" ..
        "    return " .. run_vm_A_name .. "(" .. protos_name .. "[#" .. protos_name .. "], {})\n" ..
        "end\n"

    if depth < 1 then
        wrapper_code = _G.obfuscate(wrapper_code, anti_debug, depth + 1)
    end

    -- Encrypt wrapper_code using LCG rolling key cipher
    local key = seed
    local enc_bytes = {}
    for i = 1, #wrapper_code do
        key = (key * 1103515245 + 12345) & 0xFFFFFFFF
        local b = string.byte(wrapper_code, i)
        enc_bytes[i] = string.char((b ~ (key >> 16)) & 0xFF)
    end
    local encrypted_vm = table.concat(enc_bytes)

    local escaped_vm = {}
    for i = 1, #encrypted_vm do
        table.insert(escaped_vm, string.format("\\%d", string.byte(encrypted_vm, i)))
    end

    local final_output = [=[-- Defense-grade AST-based Virtualized Obfuscation Output
local vm_a_data = "]=] .. table.concat(escaped_A) .. [=["
local vm_b_data = "]=] .. table.concat(escaped_B) .. [=["
local encrypted_vm = "]=] .. table.concat(escaped_vm) .. [=["

-- Hermetic Load Sealing
local load_func = loadstring or load
local pcall_func = pcall
if pcall_func(string.dump, load_func) or pcall_func(string.dump, pcall_func) then
    error("Security violation: Hook detected")
end

local function decrypt(str, seed)
    local dec = {}
    local key = seed
    local env_get = _G or _ENV
    for i = 1, #str do
        -- Debug API Active Poisoning
        local has_hook = false
        local dbg = env_get.debug or (pcall_func and select(2, pcall_func(require, "debug")))
        if dbg and dbg.gethook and dbg.gethook() then
            has_hook = true
        end
        if dbg and dbg.getinfo then
            local success, info = pcall_func(dbg.getinfo, 2, "f")
            if success and info and info.func then
                has_hook = true
            end
        end

        if has_hook then
            key = (key * 999999 + 12345) & 0xFFFFFFFF
        else
            key = (key * 1103515245 + 12345) & 0xFFFFFFFF
        end

        local b = string.byte(str, i)
        dec[i] = string.char((b ~ (key >> 16)) & 0xFF)
    end
    return table.concat(dec)
end

local vm_factory = load_func(decrypt(encrypted_vm, ]=] .. seed .. [=[))()
return vm_factory(vm_a_data, vm_b_data, ]=] .. seed .. [=[)
]=]

    return final_output
end

if arg and #arg >= 2 then
    local in_file = arg[1]
    local out_file = arg[2]
    local anti_debug = true
    for _, a in ipairs(arg) do
        if a == "--no-antidebug" then anti_debug = false end
    end

    local f_in = io.open(in_file, "r")
    if not f_in then
        print("Error: Could not open input file " .. in_file)
        os.exit(1)
    end
    local src = f_in:read("*all")
    f_in:close()

    local success, result = pcall(_G.obfuscate, src, anti_debug)
    if not success then
        print("Obfuscation error: " .. tostring(result))
        os.exit(1)
    end

    local f_out = io.open(out_file, "w")
    if not f_out then
        print("Error: Could not open output file " .. out_file)
        os.exit(1)
    end
    f_out:write(result)
    f_out:close()
    print("Obfuscated " .. in_file .. " -> " .. out_file .. " successfully!")
end
