// B+ Lexer — token stream from .bp source

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    State, Kernel, Transition, On, To,
    Import, AtMetal, AtNuma, AtMuarch, AtNoFalseShare,
    LCurly, RCurly, LParen, RParen, LBracket, RBracket,
    Colon, Semicolon, Comma, Arrow, FatArrow,
    Ident(String), StrLit(String), NumLit(f64),
    Eof,
}

pub struct Lexer {
    chars: Vec<char>,
    pos: usize,
}

impl Lexer {
    pub fn new(input: &str) -> Self {
        Self { chars: input.chars().collect(), pos: 0 }
    }

    pub fn tokenize(&mut self) -> Vec<Token> {
        let mut tokens = Vec::new();
        loop {
            self.skip_whitespace();
            if self.pos >= self.chars.len() { tokens.push(Token::Eof); break; }
            let c = self.chars[self.pos];
            match c {
                '{' => { tokens.push(Token::LCurly); self.pos += 1; }
                '}' => { tokens.push(Token::RCurly); self.pos += 1; }
                '(' => { tokens.push(Token::LParen); self.pos += 1; }
                ')' => { tokens.push(Token::RParen); self.pos += 1; }
                '[' => { tokens.push(Token::LBracket); self.pos += 1; }
                ']' => { tokens.push(Token::RBracket); self.pos += 1; }
                ':' => { tokens.push(Token::Colon); self.pos += 1; }
                ';' => { tokens.push(Token::Semicolon); self.pos += 1; }
                ',' => { tokens.push(Token::Comma); self.pos += 1; }
                '=' => { if self.peek() == '>' { tokens.push(Token::FatArrow); self.pos += 2; } else { self.pos += 1; } }
                '-' => { if self.peek() == '>' { tokens.push(Token::Arrow); self.pos += 2; } else { self.pos += 1; } }
                '"' => { tokens.push(self.read_string()); }
                '@' => { tokens.push(self.read_at_directive()); }
                '/' => { if self.peek() == '/' { self.skip_line(); } else { self.pos += 1; } }
                _ if c.is_alphabetic() || c == '_' => { tokens.push(self.read_ident()); }
                _ if c.is_ascii_digit() || c == '.' => { tokens.push(self.read_number()); }
                _ => { self.pos += 1; }
            }
        }
        tokens
    }

    fn peek(&self) -> char { self.chars.get(self.pos + 1).copied().unwrap_or('\0') }

    fn skip_whitespace(&mut self) {
        while self.pos < self.chars.len() && self.chars[self.pos].is_whitespace() {
            self.pos += 1;
        }
    }

    fn skip_line(&mut self) {
        while self.pos < self.chars.len() && self.chars[self.pos] != '\n' { self.pos += 1; }
    }

    fn read_string(&mut self) -> Token {
        self.pos += 1; // skip "
        let start = self.pos;
        while self.pos < self.chars.len() && self.chars[self.pos] != '"' { self.pos += 1; }
        let s: String = self.chars[start..self.pos].iter().collect();
        self.pos += 1; // skip "
        Token::StrLit(s)
    }

    fn read_at_directive(&mut self) -> Token {
        self.pos += 1; // skip @
        let start = self.pos;
        while self.pos < self.chars.len() && self.chars[self.pos].is_alphabetic() { self.pos += 1; }
        let s: String = self.chars[start..self.pos].iter().collect();
        match s.as_str() {
            "metal" => Token::AtMetal,
            "numa" => Token::AtNuma,
            "muarch" => Token::AtMuarch,
            "no_false_share" => Token::AtNoFalseShare,
            _ => Token::Ident(format!("@{}", s)),
        }
    }

    fn read_ident(&mut self) -> Token {
        let start = self.pos;
        while self.pos < self.chars.len() && (self.chars[self.pos].is_alphanumeric() || self.chars[self.pos] == '_') {
            self.pos += 1;
        }
        let s: String = self.chars[start..self.pos].iter().collect();
        match s.as_str() {
            "state" => Token::State,
            "kernel" => Token::Kernel,
            "transition" => Token::Transition,
            "on" => Token::On,
            "to" => Token::To,
            "import" => Token::Import,
            _ => Token::Ident(s),
        }
    }

    fn read_number(&mut self) -> Token {
        let start = self.pos;
        while self.pos < self.chars.len() && (self.chars[self.pos].is_ascii_digit() || self.chars[self.pos] == '.') {
            self.pos += 1;
        }
        let s: String = self.chars[start..self.pos].iter().collect();
        let n: f64 = s.parse().unwrap_or(0.0);
        Token::NumLit(n)
    }
}
