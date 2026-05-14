use crate::ast::nodes::*;
use crate::frontend::lexer::{Lexer, Token};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(input: &str) -> Self {
        let tokens = Lexer::new(input).tokenize();
        Self { tokens, pos: 0 }
    }

    pub fn parse(&mut self) -> Result<ProgramNode, String> {
        let mut states = Vec::new();
        let mut kernels = Vec::new();
        let mut imports = Vec::new();
        loop {
            match self.peek() {
                None | Some(&Token::Eof) => break,
                Some(&Token::Import) => { imports.push(self.parse_import()?); }
                Some(&Token::State) => { states.push(self.parse_state()?); }
                Some(&Token::Kernel) => { kernels.push(self.parse_kernel()?); }
                Some(t) => { return Err(format!("Unexpected token {:?}", t)); }
            }
        }
        Ok(ProgramNode { states, kernels, imports })
    }

    fn peek(&self) -> Option<&Token> { self.tokens.get(self.pos) }
    fn advance(&mut self) { self.pos += 1; }

    fn expect(&mut self, expected: Token) -> Result<(), String> {
        match self.peek() {
            Some(t) if *t == expected => { self.advance(); Ok(()) }
            Some(t) => Err(format!("Expected {:?}, got {:?}", expected, t)),
            None => Err(format!("Expected {:?}, got EOF", expected)),
        }
    }

    fn parse_import(&mut self) -> Result<ImportNode, String> {
        self.advance();
        match self.peek() {
            Some(Token::StrLit(s)) => { let path = s.clone(); self.advance(); Ok(ImportNode { path }) }
            Some(t) => Err(format!("Expected string literal in import, got {:?}", t)),
            None => Err("Unexpected EOF in import".into()),
        }
    }

    fn parse_state(&mut self) -> Result<StateDefNode, String> {
        self.advance();
        let name = match self.peek() {
            Some(Token::Ident(s)) => { let n = s.clone(); self.advance(); n }
            Some(t) => return Err(format!("Expected state name, got {:?}", t)),
            None => return Err("Unexpected EOF in state".into()),
        };
        self.expect(Token::LCurly)?;
        let mut variables = Vec::new();
        let mut transitions = Vec::new();
        let mut actions = Vec::new();
        loop {
            match self.peek() {
                Some(&Token::RCurly) => { self.advance(); break; }
                Some(&Token::Transition) => { transitions.push(self.parse_transition()?); }
                Some(&Token::On) => { actions.push(self.parse_action()?); }
                Some(Token::Ident(_)) => { variables.push(self.parse_variable()?); }
                Some(t) => return Err(format!("Unexpected token in state body: {:?}", t)),
                None => return Err("Unexpected EOF in state body".into()),
            }
        }
        Ok(StateDefNode { name, variables, transitions, actions })
    }

    fn parse_variable(&mut self) -> Result<VariableNode, String> {
        let name = match self.peek() {
            Some(Token::Ident(s)) => { let n = s.clone(); self.advance(); n }
            Some(t) => return Err(format!("Expected variable name, got {:?}", t)),
            None => return Err("Unexpected EOF in variable".into()),
        };
        self.expect(Token::Colon)?;
        let var_type = match self.peek() {
            Some(Token::Ident(s)) => { let t = s.clone(); self.advance(); t }
            Some(t) => return Err(format!("Expected type, got {:?}", t)),
            None => return Err("Unexpected EOF in variable type".into()),
        };
        let is_fast_path = matches!(self.peek(), Some(Token::AtMetal));
        if is_fast_path { self.advance(); }
        self.expect(Token::Semicolon)?;
        Ok(VariableNode { name, var_type, is_fast_path })
    }

    fn parse_transition(&mut self) -> Result<TransitionNode, String> {
        self.advance();
        let event = match self.peek() {
            Some(Token::Ident(s)) => { let e = s.clone(); self.advance(); e }
            Some(t) => return Err(format!("Expected event name, got {:?}", t)),
            None => return Err("Unexpected EOF in transition event".into()),
        };
        self.expect(Token::Arrow)?;
        let target = match self.peek() {
            Some(Token::Ident(s)) => { let t = s.clone(); self.advance(); t }
            Some(t) => return Err(format!("Expected target state, got {:?}", t)),
            None => return Err("Unexpected EOF in transition target".into()),
        };
        let mut hot_weight = None;
        if matches!(self.peek(), Some(Token::FatArrow)) {
            self.advance();
            if let Some(Token::NumLit(n)) = self.peek() {
                hot_weight = Some(*n); self.advance();
            }
        }
        self.expect(Token::Semicolon)?;
        Ok(TransitionNode { event, target, hot_weight, guard: None })
    }

    fn parse_action(&mut self) -> Result<ActionNode, String> {
        self.advance();
        let mut body = String::new();
        loop {
            match self.peek() {
                Some(&Token::Semicolon) => { self.advance(); break; }
                Some(t) => { body.push_str(&format!("{:?} ", t)); self.advance(); }
                None => return Err("Unexpected EOF in action".into()),
            }
        }
        Ok(ActionNode { body: body.trim().to_string() })
    }

    fn parse_kernel(&mut self) -> Result<KernelDecl, String> {
        self.advance();
        let name = match self.peek() {
            Some(Token::Ident(s)) => { let n = s.clone(); self.advance(); n }
            Some(t) => return Err(format!("Expected kernel name, got {:?}", t)),
            None => return Err("Unexpected EOF in kernel".into()),
        };
        self.expect(Token::LParen)?;
        let mut params = Vec::new();
        if !matches!(self.peek(), Some(&Token::RParen)) {
            loop {
                let pname = match self.peek() {
                    Some(Token::Ident(s)) => { let n = s.clone(); self.advance(); n }
                    Some(t) => return Err(format!("Expected param name, got {:?}", t)),
                    None => return Err("Unexpected EOF in kernel params".into()),
                };
                self.expect(Token::Colon)?;
                let ptype = match self.peek() {
                    Some(Token::Ident(s)) => { let t = s.clone(); self.advance(); t }
                    Some(t) => return Err(format!("Expected param type, got {:?}", t)),
                    None => return Err("Unexpected EOF in kernel param type".into()),
                };
                params.push(KernelParam { name: pname, param_type: ptype });
                if matches!(self.peek(), Some(&Token::Comma)) { self.advance(); } else { break; }
            }
        }
        self.expect(Token::RParen)?;
        Ok(KernelDecl { name, params })
    }
}
