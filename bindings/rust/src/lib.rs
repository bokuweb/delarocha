use std::cmp::Ordering;
use std::ffi::NulError;
#[cfg(feature = "vibrato-system")]
use std::io::BufReader;
use std::io::Read;
use std::ops::Range;
#[cfg(feature = "vibrato-system")]
use std::path::Path;

const UNKNOWN_WORD_BASE: u32 = 1 << 31;
const USER_WORD_BASE: u32 = 1 << 30;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid dictionary: {0}")]
    InvalidDictionary(String),
    #[error("tokenization failed: {0}")]
    Tokenization(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("path contains interior NUL byte")]
    Nul(#[from] NulError),
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Debug)]
pub struct Dictionary {
    entries: Vec<Entry>,
    user_entries: Vec<Entry>,
    matrix: ConnectionMatrix,
    char_property: CharProperty,
    unk_entries: Vec<UnkEntry>,
}

#[derive(Clone, Debug)]
struct Entry {
    surface: String,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
    feature: String,
}

#[derive(Clone, Debug)]
struct ConnectionMatrix {
    left_size: usize,
    right_size: usize,
    costs: Vec<i16>,
}

#[derive(Clone, Debug)]
struct CharProperty {
    categories: Vec<CharCategory>,
    ranges: Vec<CharRange>,
}

#[derive(Clone, Debug)]
struct CharCategory {
    name: String,
    invoke: bool,
    group: bool,
    length: usize,
}

#[derive(Clone, Debug)]
struct CharRange {
    start: u32,
    end: u32,
    category_ids: Vec<usize>,
}

#[derive(Clone, Debug)]
struct CharInfo<'a> {
    base_id: usize,
    category_ids: &'a [usize],
    category: &'a CharCategory,
}

#[derive(Clone, Debug)]
struct UnkEntry {
    category_id: usize,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
    feature: String,
}

impl Dictionary {
    pub fn parse(input: &str) -> Result<Self> {
        let mut matrix: Option<ConnectionMatrix> = None;
        let mut pending_matrix_rows = 0usize;
        let mut entries = Vec::new();

        for (line_no, raw_line) in input.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            if pending_matrix_rows > 0 {
                let row = parse_i16_row(line, line_no + 1)?;
                let matrix = matrix
                    .as_mut()
                    .ok_or_else(|| Error::InvalidDictionary("matrix row before header".into()))?;
                if row.len() != matrix.left_size {
                    return Err(Error::InvalidDictionary(format!(
                        "line {} has {} matrix columns, expected {}",
                        line_no + 1,
                        row.len(),
                        matrix.left_size
                    )));
                }
                matrix.costs.extend(row);
                pending_matrix_rows -= 1;
                continue;
            }

            let fields: Vec<_> = line.split('\t').collect();
            match fields.as_slice() {
                ["matrix", right_size, left_size] => {
                    let right_size = parse_usize(right_size, line_no + 1, "right_size")?;
                    let left_size = parse_usize(left_size, line_no + 1, "left_size")?;
                    matrix = Some(ConnectionMatrix {
                        left_size,
                        right_size,
                        costs: Vec::with_capacity(right_size * left_size),
                    });
                    pending_matrix_rows = right_size;
                }
                ["entry", surface, left_id, right_id, word_cost, feature] => {
                    entries.push(Entry {
                        surface: (*surface).to_owned(),
                        left_id: parse_u16(left_id, line_no + 1, "left_id")?,
                        right_id: parse_u16(right_id, line_no + 1, "right_id")?,
                        word_cost: parse_i32(word_cost, line_no + 1, "word_cost")?,
                        feature: (*feature).to_owned(),
                    });
                }
                _ => {
                    return Err(Error::InvalidDictionary(format!(
                        "line {} is not a matrix or entry record",
                        line_no + 1
                    )));
                }
            }
        }

        if pending_matrix_rows != 0 {
            return Err(Error::InvalidDictionary("matrix is missing rows".into()));
        }

        let matrix = matrix.ok_or_else(|| Error::InvalidDictionary("missing matrix".into()))?;
        if matrix.costs.len() != matrix.right_size * matrix.left_size {
            return Err(Error::InvalidDictionary("matrix size mismatch".into()));
        }
        if entries.is_empty() {
            return Err(Error::InvalidDictionary("missing entries".into()));
        }

        Ok(Self {
            entries,
            user_entries: Vec::new(),
            matrix,
            char_property: CharProperty::default(),
            unk_entries: vec![UnkEntry {
                category_id: 0,
                left_id: 0,
                right_id: 0,
                word_cost: 10_000,
                feature: "UNK".to_owned(),
            }],
        })
    }
}

pub struct SystemDictionaryBuilder;

impl SystemDictionaryBuilder {
    pub fn from_readers<L, M, C, U>(
        mut lexicon: L,
        mut matrix: M,
        mut char_def: C,
        mut unk_def: U,
    ) -> Result<Dictionary>
    where
        L: Read,
        M: Read,
        C: Read,
        U: Read,
    {
        let mut lexicon_buf = Vec::new();
        let mut matrix_buf = String::new();
        let mut char_buf = String::new();
        let mut unk_buf = Vec::new();
        lexicon
            .read_to_end(&mut lexicon_buf)
            .map_err(|err| Error::InvalidDictionary(err.to_string()))?;
        matrix
            .read_to_string(&mut matrix_buf)
            .map_err(|err| Error::InvalidDictionary(err.to_string()))?;
        char_def
            .read_to_string(&mut char_buf)
            .map_err(|err| Error::InvalidDictionary(err.to_string()))?;
        unk_def
            .read_to_end(&mut unk_buf)
            .map_err(|err| Error::InvalidDictionary(err.to_string()))?;

        let entries = parse_mecab_entries(&lexicon_buf, "lex.csv")?;
        let matrix = ConnectionMatrix::parse_mecab(&matrix_buf)?;
        let char_property = CharProperty::parse(&char_buf)?;
        let unk_entries = parse_unk_entries(&unk_buf, &char_property)?;
        validate_connection_ids(&entries, &unk_entries, &matrix)?;

        Ok(Dictionary {
            entries,
            user_entries: Vec::new(),
            matrix,
            char_property,
            unk_entries,
        })
    }
}

impl Dictionary {
    pub fn reset_user_lexicon_from_reader<R>(mut self, reader: Option<R>) -> Result<Self>
    where
        R: Read,
    {
        self.user_entries = if let Some(mut reader) = reader {
            let mut buf = Vec::new();
            reader.read_to_end(&mut buf)?;
            let entries = parse_mecab_entries(&buf, "user.csv")?;
            validate_connection_ids(&entries, &[], &self.matrix)?;
            entries
        } else {
            Vec::new()
        };
        Ok(self)
    }
}

#[cfg(feature = "vibrato-system")]
pub struct VibratoSystemDictionary {
    inner: vibrato::Dictionary,
}

#[cfg(feature = "vibrato-system")]
pub struct VibratoSystemTokenizer {
    inner: vibrato::Tokenizer,
}

#[cfg(feature = "vibrato-system")]
pub struct VibratoSystemWorker<'a> {
    inner: vibrato::tokenizer::worker::Worker<'a>,
}

#[cfg(feature = "vibrato-system")]
pub struct VibratoSystemToken<'w, 't> {
    inner: vibrato::token::Token<'w, 't>,
}

#[cfg(feature = "vibrato-system")]
impl VibratoSystemDictionary {
    /// Reads an uncompressed Vibrato `system.dic` stream.
    pub fn read<R>(reader: R) -> Result<Self>
    where
        R: Read,
    {
        let inner = vibrato::Dictionary::read(BufReader::new(reader))
            .map_err(|err| Error::InvalidDictionary(err.to_string()))?;
        Ok(Self { inner })
    }

    /// Reads a zstd-compressed Vibrato `system.dic.zst` stream.
    pub fn read_zstd<R>(reader: R) -> Result<Self>
    where
        R: Read,
    {
        let decoder = zstd::Decoder::new(reader)?;
        Self::read(decoder)
    }

    /// Reads `system.dic` or `system.dic.zst`, selected by the file extension.
    pub fn from_path(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let file = std::fs::File::open(path)?;
        if path.extension().is_some_and(|extension| extension == "zst") {
            Self::read_zstd(file)
        } else {
            Self::read(file)
        }
    }

    /// Creates a tokenizer backed by the loaded Vibrato system dictionary.
    pub fn into_tokenizer(self) -> VibratoSystemTokenizer {
        VibratoSystemTokenizer {
            inner: vibrato::Tokenizer::new(self.inner),
        }
    }
}

#[cfg(feature = "vibrato-system")]
impl VibratoSystemTokenizer {
    /// Creates a tokenizer backed by a loaded Vibrato system dictionary.
    pub fn new(dictionary: VibratoSystemDictionary) -> Self {
        dictionary.into_tokenizer()
    }

    /// Mirrors Vibrato's MeCab-compatible space skipping option.
    pub fn ignore_space(mut self, yes: bool) -> Result<Self> {
        self.inner = self
            .inner
            .ignore_space(yes)
            .map_err(|err| Error::InvalidDictionary(err.to_string()))?;
        Ok(self)
    }

    /// Mirrors Vibrato's maximum unknown grouping length option.
    pub fn max_grouping_len(mut self, max_grouping_len: usize) -> Self {
        self.inner = self.inner.max_grouping_len(max_grouping_len);
        self
    }

    /// Creates a reusable worker for repeated tokenization with stable scratch buffers.
    pub fn new_worker(&self) -> VibratoSystemWorker<'_> {
        VibratoSystemWorker {
            inner: self.inner.new_worker(),
        }
    }

    /// Tokenizes valid UTF-8 input and maps Vibrato tokens into delarocha tokens.
    pub fn tokenize(&self, input: &str) -> Result<Vec<Token>> {
        let mut worker = self.new_worker();
        worker.tokenize(input);
        Ok(worker
            .token_iter()
            .map(Token::from_vibrato_system)
            .collect())
    }
}

#[cfg(feature = "vibrato-system")]
impl<'a> VibratoSystemWorker<'a> {
    /// Resets the reusable worker to a new UTF-8 input sentence.
    pub fn reset_sentence(&mut self, input: &str) {
        self.inner.reset_sentence(input);
    }

    /// Runs tokenization for the sentence currently set on this worker.
    pub fn tokenize_current(&mut self) {
        self.inner.tokenize();
    }

    /// Resets this worker to `input`, tokenizes it, and keeps borrowed tokens available.
    pub fn tokenize(&mut self, input: &str) {
        self.reset_sentence(input);
        self.tokenize_current();
    }

    /// Returns borrowed tokens without allocating an owned token vector.
    pub fn token_iter(&self) -> impl Iterator<Item = VibratoSystemToken<'_, 'a>> + '_ {
        self.inner
            .token_iter()
            .map(|inner| VibratoSystemToken { inner })
    }

    /// Returns the number of tokens produced by the last tokenization.
    pub fn num_tokens(&self) -> usize {
        self.inner.num_tokens()
    }
}

#[cfg(feature = "vibrato-system")]
impl VibratoSystemToken<'_, '_> {
    /// Gets the token surface as a borrowed slice of the input sentence.
    pub fn surface(&self) -> &str {
        self.inner.surface()
    }

    /// Gets the token feature string borrowed from the dictionary.
    pub fn feature(&self) -> &str {
        self.inner.feature()
    }

    /// Gets the token byte range in the input sentence.
    pub fn range_byte(&self) -> Range<usize> {
        self.inner.range_byte()
    }

    /// Gets the token character range in the input sentence.
    pub fn range_char(&self) -> Range<usize> {
        self.inner.range_char()
    }

    /// Gets the encoded delarocha word id, including lexical-type high bits.
    pub fn word_id(&self) -> u32 {
        let word_idx = self.inner.word_idx();
        match word_idx.lex_type {
            vibrato::dictionary::LexType::System => word_idx.word_id,
            vibrato::dictionary::LexType::User => USER_WORD_BASE + word_idx.word_id,
            vibrato::dictionary::LexType::Unknown => UNKNOWN_WORD_BASE + word_idx.word_id,
        }
    }

    /// Returns true when this token comes from an unknown-word entry.
    pub fn is_unknown(&self) -> bool {
        self.inner.lex_type() == vibrato::dictionary::LexType::Unknown
    }

    /// Gets the total path cost from BOS to this token.
    pub fn total_cost(&self) -> i32 {
        self.inner.total_cost()
    }
}

impl ConnectionMatrix {
    fn parse_mecab(input: &str) -> Result<Self> {
        let mut lines = input.lines().filter(|line| !line.trim().is_empty());
        let header = lines
            .next()
            .ok_or_else(|| Error::InvalidDictionary("matrix.def is empty".into()))?;
        let header_fields: Vec<_> = header.split_whitespace().collect();
        let [right_size, left_size] = header_fields.as_slice() else {
            return Err(Error::InvalidDictionary(
                "matrix.def header must have two integers".into(),
            ));
        };
        let right_size = right_size
            .parse::<usize>()
            .map_err(|_| Error::InvalidDictionary("invalid matrix right size".into()))?;
        let left_size = left_size
            .parse::<usize>()
            .map_err(|_| Error::InvalidDictionary("invalid matrix left size".into()))?;
        let mut costs = vec![0; right_size * left_size];

        for line in lines {
            let fields: Vec<_> = line.split_whitespace().collect();
            let [right_id, left_id, cost] = fields.as_slice() else {
                return Err(Error::InvalidDictionary(format!(
                    "invalid matrix row: {line}"
                )));
            };
            let right_id = right_id
                .parse::<usize>()
                .map_err(|_| Error::InvalidDictionary(format!("invalid right id: {line}")))?;
            let left_id = left_id
                .parse::<usize>()
                .map_err(|_| Error::InvalidDictionary(format!("invalid left id: {line}")))?;
            let cost = cost
                .parse::<i16>()
                .map_err(|_| Error::InvalidDictionary(format!("invalid matrix cost: {line}")))?;
            if right_id >= right_size || left_id >= left_size {
                return Err(Error::InvalidDictionary("matrix id out of range".into()));
            }
            costs[left_id * right_size + right_id] = cost;
        }

        Ok(Self {
            left_size,
            right_size,
            costs,
        })
    }

    #[inline]
    fn cost(&self, right_id: u16, left_id: u16) -> i32 {
        let right = usize::from(right_id);
        let left = usize::from(left_id);
        if right >= self.right_size || left >= self.left_size {
            return i32::MAX / 4;
        }
        i32::from(self.costs[left * self.right_size + right])
    }
}

impl CharProperty {
    fn default() -> Self {
        Self {
            categories: vec![CharCategory {
                name: "DEFAULT".to_owned(),
                invoke: false,
                group: false,
                length: 0,
            }],
            ranges: Vec::new(),
        }
    }

    fn parse(input: &str) -> Result<Self> {
        let mut property = Self::default();
        property.categories.clear();

        for raw_line in input.lines() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with("0x") {
                let fields: Vec<_> = line.split_whitespace().collect();
                if fields.len() < 2 {
                    return Err(Error::InvalidDictionary(format!(
                        "invalid char range: {line}"
                    )));
                }
                let (start, end) = parse_codepoint_range(fields[0])?;
                let category_ids = fields[1..]
                    .iter()
                    .take_while(|category| !category.starts_with('#'))
                    .map(|category| {
                        property.category_id(category).ok_or_else(|| {
                            Error::InvalidDictionary(format!("undefined char category: {category}"))
                        })
                    })
                    .collect::<Result<Vec<_>>>()?;
                if category_ids.is_empty() {
                    return Err(Error::InvalidDictionary(format!(
                        "invalid char range: {line}"
                    )));
                }
                property.ranges.push(CharRange {
                    start,
                    end,
                    category_ids,
                });
            } else {
                let fields: Vec<_> = line.split_whitespace().collect();
                if fields.len() < 4 {
                    return Err(Error::InvalidDictionary(format!(
                        "invalid char category: {line}"
                    )));
                }
                property.categories.push(CharCategory {
                    name: fields[0].to_owned(),
                    invoke: parse_bool01(fields[1], "INVOKE")?,
                    group: parse_bool01(fields[2], "GROUP")?,
                    length: fields[3]
                        .parse()
                        .map_err(|_| Error::InvalidDictionary(format!("invalid length: {line}")))?,
                });
            }
        }

        if property.category_id("DEFAULT").is_none() {
            return Err(Error::InvalidDictionary(
                "char.def must define DEFAULT".into(),
            ));
        }
        Ok(property)
    }

    fn category_id(&self, name: &str) -> Option<usize> {
        self.categories
            .iter()
            .position(|category| category.name == name)
    }

    fn category_for(&self, ch: char) -> CharInfo<'_> {
        let cp = u32::from(ch);
        let range = self
            .ranges
            .iter()
            .rev()
            .find(|range| range.start <= cp && cp < range.end);
        let category_ids = range.map_or(&[0][..], |range| range.category_ids.as_slice());
        let base_id = category_ids[0];
        CharInfo {
            base_id,
            category_ids,
            category: &self.categories[base_id],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    pub surface: String,
    pub start: usize,
    pub end: usize,
    pub start_char: usize,
    pub end_char: usize,
    pub word_id: u32,
    pub feature: String,
    pub total_cost: i32,
}

impl Token {
    #[cfg(feature = "vibrato-system")]
    fn from_vibrato_system(token: VibratoSystemToken<'_, '_>) -> Self {
        let range_byte = token.range_byte();
        let range_char = token.range_char();
        Self {
            surface: token.surface().to_owned(),
            start: range_byte.start,
            end: range_byte.end,
            start_char: range_char.start,
            end_char: range_char.end,
            word_id: token.word_id(),
            feature: token.feature().to_owned(),
            total_cost: token.total_cost(),
        }
    }

    pub fn byte_range(&self) -> Range<usize> {
        self.start..self.end
    }

    pub fn range_byte(&self) -> Range<usize> {
        self.byte_range()
    }

    pub fn range_char(&self) -> Range<usize> {
        self.start_char..self.end_char
    }

    pub fn surface(&self) -> &str {
        &self.surface
    }

    pub fn feature(&self) -> &str {
        &self.feature
    }

    pub fn total_cost(&self) -> i32 {
        self.total_cost
    }

    pub fn is_unknown(&self) -> bool {
        self.word_id >= UNKNOWN_WORD_BASE
    }
}

#[derive(Clone, Debug)]
pub struct Tokenizer {
    dictionary: Dictionary,
    ignore_space_category: Option<usize>,
    max_grouping_len: Option<usize>,
}

impl Tokenizer {
    pub fn new(dictionary: Dictionary) -> Self {
        Self {
            dictionary,
            ignore_space_category: None,
            max_grouping_len: None,
        }
    }

    pub fn ignore_space(mut self, yes: bool) -> Result<Self> {
        self.ignore_space_category = if yes {
            Some(
                self.dictionary
                    .char_property
                    .category_id("SPACE")
                    .ok_or_else(|| {
                        Error::InvalidDictionary("SPACE category is not defined".into())
                    })?,
            )
        } else {
            None
        };
        Ok(self)
    }

    pub fn max_grouping_len(mut self, max_grouping_len: usize) -> Self {
        self.max_grouping_len = (max_grouping_len != 0).then_some(max_grouping_len);
        self
    }

    pub fn tokenize(&self, input: &str) -> Result<Vec<Token>> {
        let mut worker = self.create_worker();
        worker.tokenize(input).map(ToOwned::to_owned)
    }

    pub fn create_worker(&self) -> Worker<'_> {
        Worker {
            dictionary: &self.dictionary,
            ignore_space_category: self.ignore_space_category,
            max_grouping_len: self.max_grouping_len,
            nodes: Vec::new(),
            ends: Vec::new(),
            tokens: Vec::new(),
        }
    }

    pub fn new_worker(&self) -> CompatWorker<'_> {
        CompatWorker {
            worker: self.create_worker(),
            input: String::new(),
        }
    }
}

#[derive(Debug)]
pub struct CompatWorker<'dict> {
    worker: Worker<'dict>,
    input: String,
}

impl CompatWorker<'_> {
    pub fn reset_sentence<S: AsRef<str>>(&mut self, input: S) {
        self.input.clear();
        self.input.push_str(input.as_ref());
        self.worker.tokens.clear();
    }

    pub fn tokenize(&mut self) {
        self.worker
            .tokenize(&self.input)
            .expect("tokenization should not fail for valid UTF-8 input");
    }

    pub fn num_tokens(&self) -> usize {
        self.worker.tokens.len()
    }

    pub fn token(&self, i: usize) -> &Token {
        &self.worker.tokens[i]
    }

    pub fn token_iter(&self) -> impl Iterator<Item = &Token> {
        self.worker.tokens.iter()
    }
}

#[derive(Debug)]
pub struct Worker<'dict> {
    dictionary: &'dict Dictionary,
    ignore_space_category: Option<usize>,
    max_grouping_len: Option<usize>,
    nodes: Vec<Node>,
    ends: Vec<Vec<usize>>,
    tokens: Vec<Token>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
struct Node {
    word_id: u32,
    start: usize,
    end: usize,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
    min_cost: i32,
    prev_node: Option<usize>,
}

impl<'dict> Worker<'dict> {
    pub fn tokenize(&mut self, input: &str) -> Result<&[Token]> {
        self.reset(input.len());
        if input.is_empty() {
            return Ok(&self.tokens);
        }

        self.nodes.push(Node::bos());
        self.ends[0].push(0);

        for begin in char_boundaries(input) {
            if begin == input.len() || self.ends[begin].is_empty() {
                continue;
            }
            if let Some(space_category) = self.ignore_space_category {
                let ch = input[begin..]
                    .chars()
                    .next()
                    .ok_or_else(|| Error::Tokenization("missing character at boundary".into()))?;
                let info = self.dictionary.char_property.category_for(ch);
                if info.category_ids.contains(&space_category) {
                    let end = group_end(input, begin, &self.dictionary.char_property, &info);
                    let prev_nodes = self.ends[begin].clone();
                    self.ends[end].extend(prev_nodes);
                    continue;
                }
            }

            let mut emitted = false;
            for (word_id, entry) in self.dictionary.user_entries.iter().enumerate() {
                if input[begin..].starts_with(&entry.surface) {
                    let end = begin + entry.surface.len();
                    if !input.is_char_boundary(end) {
                        continue;
                    }
                    self.append_best_node(
                        begin,
                        end,
                        Candidate {
                            word_id: USER_WORD_BASE + word_id as u32,
                            left_id: entry.left_id,
                            right_id: entry.right_id,
                            word_cost: entry.word_cost,
                        },
                    )?;
                    emitted = true;
                }
            }
            for (word_id, entry) in self.dictionary.entries.iter().enumerate() {
                if input[begin..].starts_with(&entry.surface) {
                    let end = begin + entry.surface.len();
                    if !input.is_char_boundary(end) {
                        continue;
                    }
                    self.append_best_node(
                        begin,
                        end,
                        Candidate {
                            word_id: word_id as u32,
                            left_id: entry.left_id,
                            right_id: entry.right_id,
                            word_cost: entry.word_cost,
                        },
                    )?;
                    emitted = true;
                }
            }

            self.append_unknown_nodes(input, begin, emitted)?;
        }

        let best = self.ends[input.len()]
            .iter()
            .copied()
            .min_by(|left, right| compare_node_cost(&self.nodes[*left], &self.nodes[*right]))
            .ok_or_else(|| Error::Tokenization("no path reached the end of input".into()))?;
        self.backtrace(input, best)?;
        Ok(&self.tokens)
    }

    fn reset(&mut self, len: usize) {
        self.nodes.clear();
        self.tokens.clear();
        self.ends.clear();
        self.ends.resize_with(len + 1, Vec::new);
    }

    fn append_best_node(&mut self, begin: usize, end: usize, candidate: Candidate) -> Result<()> {
        let (prev_node, min_cost) = self.find_best_prev(begin, candidate)?;
        let index = self.nodes.len();
        self.nodes.push(Node {
            word_id: candidate.word_id,
            start: begin,
            end,
            left_id: candidate.left_id,
            right_id: candidate.right_id,
            word_cost: candidate.word_cost,
            min_cost,
            prev_node: Some(prev_node),
        });
        self.ends[end].push(index);
        Ok(())
    }

    fn append_unknown_nodes(&mut self, input: &str, begin: usize, has_matched: bool) -> Result<()> {
        let ch = input[begin..]
            .chars()
            .next()
            .ok_or_else(|| Error::Tokenization("missing character at unknown boundary".into()))?;
        let info = self.dictionary.char_property.category_for(ch);
        if has_matched && !info.category.invoke {
            return Ok(());
        }

        let mut emitted = false;
        for (unk_id, unk) in self
            .dictionary
            .unk_entries
            .iter()
            .enumerate()
            .filter(|(_, unk)| unk.category_id == info.base_id)
        {
            let group_end = group_end(input, begin, &self.dictionary.char_property, &info);
            let group_len = input[begin..group_end].chars().count();
            let mut grouped = false;
            if info.category.group
                && self
                    .max_grouping_len
                    .is_none_or(|max| group_len.saturating_sub(1) <= max)
            {
                self.append_best_node(
                    begin,
                    group_end,
                    Candidate {
                        word_id: UNKNOWN_WORD_BASE + unk_id as u32,
                        left_id: unk.left_id,
                        right_id: unk.right_id,
                        word_cost: unk.word_cost,
                    },
                )?;
                emitted = true;
                grouped = true;
            }

            for len in 1..=info.category.length.min(group_len) {
                if grouped && len == group_len {
                    continue;
                }
                let end = nth_char_boundary(input, begin, len)?;
                self.append_best_node(
                    begin,
                    end,
                    Candidate {
                        word_id: UNKNOWN_WORD_BASE + unk_id as u32,
                        left_id: unk.left_id,
                        right_id: unk.right_id,
                        word_cost: unk.word_cost,
                    },
                )?;
                emitted = true;
            }
        }

        if !has_matched && !emitted {
            let end = next_char_boundary(input, begin)?;
            let fallback = self
                .dictionary
                .unk_entries
                .iter()
                .enumerate()
                .find(|(_, unk)| unk.category_id == info.base_id);
            let (word_id, left_id, right_id, word_cost) =
                fallback.map_or((UNKNOWN_WORD_BASE, 0, 0, 10_000), |(unk_id, unk)| {
                    (
                        UNKNOWN_WORD_BASE + unk_id as u32,
                        unk.left_id,
                        unk.right_id,
                        unk.word_cost,
                    )
                });
            self.append_best_node(
                begin,
                end,
                Candidate {
                    word_id,
                    left_id,
                    right_id,
                    word_cost,
                },
            )?;
        }
        Ok(())
    }

    fn find_best_prev(&self, begin: usize, candidate: Candidate) -> Result<(usize, i32)> {
        self.ends[begin]
            .iter()
            .copied()
            .map(|prev_index| {
                let prev = &self.nodes[prev_index];
                let cost = prev.min_cost
                    + self
                        .dictionary
                        .matrix
                        .cost(prev.right_id, candidate.left_id)
                    + candidate.word_cost;
                (prev_index, cost)
            })
            .min_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(&left.0)))
            .ok_or_else(|| Error::Tokenization("candidate has no previous node".into()))
    }

    fn backtrace(&mut self, input: &str, mut index: usize) -> Result<()> {
        let mut reversed = Vec::new();
        while let Some(prev) = self.nodes[index].prev_node {
            let node = &self.nodes[index];
            let (surface, feature) = if node.word_id >= UNKNOWN_WORD_BASE {
                let unk_index = (node.word_id - UNKNOWN_WORD_BASE) as usize;
                let feature = self
                    .dictionary
                    .unk_entries
                    .get(unk_index)
                    .map_or("UNK", |entry| entry.feature.as_str());
                (&input[node.start..node.end], feature)
            } else if node.word_id >= USER_WORD_BASE {
                let entry = self
                    .dictionary
                    .user_entries
                    .get((node.word_id - USER_WORD_BASE) as usize)
                    .ok_or_else(|| Error::Tokenization("user word id out of range".into()))?;
                (entry.surface.as_str(), entry.feature.as_str())
            } else {
                let entry = self
                    .dictionary
                    .entries
                    .get(node.word_id as usize)
                    .ok_or_else(|| Error::Tokenization("word id out of range".into()))?;
                (entry.surface.as_str(), entry.feature.as_str())
            };
            reversed.push(Token {
                surface: surface.to_owned(),
                start: node.start,
                end: node.end,
                start_char: input[..node.start].chars().count(),
                end_char: input[..node.end].chars().count(),
                word_id: node.word_id,
                feature: feature.to_owned(),
                total_cost: node.min_cost,
            });
            index = prev;
        }
        reversed.reverse();
        self.tokens = reversed;
        Ok(())
    }
}

impl Node {
    fn bos() -> Self {
        Self {
            word_id: u32::MAX,
            start: 0,
            end: 0,
            left_id: 0,
            right_id: 0,
            word_cost: 0,
            min_cost: 0,
            prev_node: None,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Candidate {
    word_id: u32,
    left_id: u16,
    right_id: u16,
    word_cost: i32,
}

fn compare_node_cost(left: &Node, right: &Node) -> Ordering {
    left.min_cost
        .cmp(&right.min_cost)
        .then_with(|| left.word_id.cmp(&right.word_id))
}

fn char_boundaries(input: &str) -> impl Iterator<Item = usize> + '_ {
    input
        .char_indices()
        .map(|(index, _)| index)
        .chain([input.len()])
}

fn next_char_boundary(input: &str, begin: usize) -> Result<usize> {
    input[begin..]
        .chars()
        .next()
        .map(|ch| begin + ch.len_utf8())
        .ok_or_else(|| Error::Tokenization("missing character at boundary".into()))
}

fn nth_char_boundary(input: &str, begin: usize, count: usize) -> Result<usize> {
    let mut end = begin;
    for _ in 0..count.max(1) {
        end = next_char_boundary(input, end)?;
        if end == input.len() {
            break;
        }
    }
    Ok(end)
}

fn group_end(
    input: &str,
    begin: usize,
    char_property: &CharProperty,
    start_info: &CharInfo<'_>,
) -> usize {
    let mut end = begin;
    while end < input.len() {
        let Some(ch) = input[end..].chars().next() else {
            break;
        };
        let next_info = char_property.category_for(ch);
        if !next_info
            .category_ids
            .iter()
            .any(|id| start_info.category_ids.contains(id))
        {
            break;
        }
        end += ch.len_utf8();
    }
    end
}

fn parse_mecab_entries(bytes: &[u8], name: &str) -> Result<Vec<Entry>> {
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(false)
        .flexible(true)
        .from_reader(bytes);
    let mut entries = Vec::new();
    for record in reader.records() {
        let record = record.map_err(|err| Error::InvalidDictionary(format!("{name}: {err}")))?;
        if record.len() < 5 {
            return Err(Error::InvalidDictionary(format!(
                "{name}: rows must have at least five fields"
            )));
        }
        let surface = record[0].to_owned();
        if surface.is_empty() {
            continue;
        }
        entries.push(Entry {
            surface,
            left_id: record[1]
                .parse()
                .map_err(|_| Error::InvalidDictionary(format!("{name}: invalid left id")))?,
            right_id: record[2]
                .parse()
                .map_err(|_| Error::InvalidDictionary(format!("{name}: invalid right id")))?,
            word_cost: record[3]
                .parse()
                .map_err(|_| Error::InvalidDictionary(format!("{name}: invalid word cost")))?,
            feature: record.iter().skip(4).collect::<Vec<_>>().join(","),
        });
    }
    Ok(entries)
}

fn parse_unk_entries(bytes: &[u8], char_property: &CharProperty) -> Result<Vec<UnkEntry>> {
    let mut entries = Vec::new();
    for entry in parse_mecab_entries(bytes, "unk.def")? {
        let category_id = char_property.category_id(&entry.surface).ok_or_else(|| {
            Error::InvalidDictionary(format!(
                "unk.def references undefined category {}",
                entry.surface
            ))
        })?;
        entries.push(UnkEntry {
            category_id,
            left_id: entry.left_id,
            right_id: entry.right_id,
            word_cost: entry.word_cost,
            feature: entry.feature,
        });
    }
    Ok(entries)
}

fn validate_connection_ids(
    entries: &[Entry],
    unk_entries: &[UnkEntry],
    matrix: &ConnectionMatrix,
) -> Result<()> {
    let valid = |left_id: u16, right_id: u16| {
        usize::from(left_id) < matrix.left_size && usize::from(right_id) < matrix.right_size
    };
    if !entries
        .iter()
        .all(|entry| valid(entry.left_id, entry.right_id))
    {
        return Err(Error::InvalidDictionary(
            "lex.csv includes invalid connection ids".into(),
        ));
    }
    if !unk_entries
        .iter()
        .all(|entry| valid(entry.left_id, entry.right_id))
    {
        return Err(Error::InvalidDictionary(
            "unk.def includes invalid connection ids".into(),
        ));
    }
    Ok(())
}

fn parse_codepoint_range(input: &str) -> Result<(u32, u32)> {
    let mut parts = input.split("..");
    let start = parse_hex_codepoint(
        parts
            .next()
            .ok_or_else(|| Error::InvalidDictionary(format!("invalid range: {input}")))?,
    )?;
    let end = match parts.next() {
        Some(end) => parse_hex_codepoint(end)? + 1,
        None => start + 1,
    };
    if parts.next().is_some() || start >= end {
        return Err(Error::InvalidDictionary(format!("invalid range: {input}")));
    }
    Ok((start, end))
}

fn parse_hex_codepoint(input: &str) -> Result<u32> {
    u32::from_str_radix(input.trim_start_matches("0x"), 16)
        .map_err(|_| Error::InvalidDictionary(format!("invalid codepoint: {input}")))
}

fn parse_bool01(input: &str, name: &str) -> Result<bool> {
    match input {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(Error::InvalidDictionary(format!("{name} must be 0 or 1"))),
    }
}

fn parse_i16_row(line: &str, line_no: usize) -> Result<Vec<i16>> {
    line.split('\t')
        .map(|field| {
            field.parse().map_err(|_| {
                Error::InvalidDictionary(format!("line {line_no} has invalid matrix cost"))
            })
        })
        .collect()
}

fn parse_usize(field: &str, line_no: usize, name: &str) -> Result<usize> {
    field
        .parse()
        .map_err(|_| Error::InvalidDictionary(format!("line {line_no} has invalid {name}")))
}

fn parse_u16(field: &str, line_no: usize, name: &str) -> Result<u16> {
    field
        .parse()
        .map_err(|_| Error::InvalidDictionary(format!("line {line_no} has invalid {name}")))
}

fn parse_i32(field: &str, line_no: usize, name: &str) -> Result<i32> {
    field
        .parse()
        .map_err(|_| Error::InvalidDictionary(format!("line {line_no} has invalid {name}")))
}

#[cfg(feature = "zig-ffi")]
pub mod ffi {
    use super::*;
    use std::ffi::{CStr, CString};
    use std::marker::PhantomData;
    use std::path::Path;
    use std::ptr::NonNull;

    #[repr(C)]
    struct RawTokenizer {
        _private: [u8; 0],
    }

    #[repr(C)]
    struct RawWorker {
        _private: [u8; 0],
    }

    unsafe extern "C" {
        fn delarocha_tokenizer_new(path: *const std::ffi::c_char) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_raw(
            lex_path: *const std::ffi::c_char,
            matrix_path: *const std::ffi::c_char,
            char_path: *const std::ffi::c_char,
            unk_path: *const std::ffi::c_char,
        ) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_raw_count_only(
            lex_path: *const std::ffi::c_char,
            matrix_path: *const std::ffi::c_char,
            char_path: *const std::ffi::c_char,
            unk_path: *const std::ffi::c_char,
        ) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_binary(path: *const std::ffi::c_char) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_binary_bytes(
            bytes_ptr: *const u8,
            bytes_len: usize,
        ) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_binary_count_only(
            path: *const std::ffi::c_char,
        ) -> *mut RawTokenizer;
        fn delarocha_dictionary_write_binary(
            lex_path: *const std::ffi::c_char,
            matrix_path: *const std::ffi::c_char,
            char_path: *const std::ffi::c_char,
            unk_path: *const std::ffi::c_char,
            output_path: *const std::ffi::c_char,
        ) -> i32;
        fn delarocha_tokenizer_free(tokenizer: *mut RawTokenizer);
        fn delarocha_worker_new(tokenizer: *mut RawTokenizer) -> *mut RawWorker;
        fn delarocha_worker_free(worker: *mut RawWorker);
        fn delarocha_tokenize(worker: *mut RawWorker, input: *const std::ffi::c_char) -> i32;
        fn delarocha_tokenize_bytes(worker: *mut RawWorker, input: *const u8, len: usize) -> i32;
        fn delarocha_tokenize_count_bytes_nonnull(
            worker: *mut RawWorker,
            input: *const u8,
            len: usize,
        ) -> usize;
        fn delarocha_tokenize_count_batch_nonnull(
            worker: *mut RawWorker,
            inputs: *const *const u8,
            lens: *const usize,
            count: usize,
        ) -> usize;
        fn delarocha_token_count(worker: *const RawWorker) -> usize;
        fn delarocha_token_surface_start(worker: *const RawWorker, index: usize) -> usize;
        fn delarocha_token_surface_end(worker: *const RawWorker, index: usize) -> usize;
        fn delarocha_token_word_id(worker: *const RawWorker, index: usize) -> u32;
        fn delarocha_tokens_copy_spans(
            worker: *const RawWorker,
            starts: *mut usize,
            ends: *mut usize,
            word_ids: *mut u32,
            cap: usize,
        ) -> usize;
        fn delarocha_token_feature(
            worker: *const RawWorker,
            index: usize,
        ) -> *const std::ffi::c_char;
        fn delarocha_last_error() -> *const std::ffi::c_char;
    }

    pub struct ZigTokenizer {
        raw: NonNull<RawTokenizer>,
    }

    pub struct ZigWorker<'tokenizer> {
        raw: NonNull<RawWorker>,
        _tokenizer: PhantomData<&'tokenizer ZigTokenizer>,
    }

    // The Zig handles are opaque pointers to native tokenizer/worker state.
    // Rust never aliases mutable access across threads: callers need `&mut
    // ZigWorker` to tokenize, and tokenizer data is immutable after loading.
    unsafe impl Send for ZigTokenizer {}
    unsafe impl Sync for ZigTokenizer {}
    unsafe impl Send for ZigWorker<'_> {}
    unsafe impl Sync for ZigWorker<'_> {}

    pub struct ZigBatch<'input> {
        ptrs: Vec<*const u8>,
        lens: Vec<usize>,
        _input: PhantomData<&'input str>,
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct ZigTokenSpan {
        pub start: usize,
        pub end: usize,
        pub word_id: u32,
    }

    impl<'input> ZigBatch<'input> {
        pub fn new(inputs: &'input [&'input str]) -> Self {
            Self {
                ptrs: inputs.iter().map(|input| input.as_ptr()).collect(),
                lens: inputs.iter().map(|input| input.len()).collect(),
                _input: PhantomData,
            }
        }
    }

    impl ZigTokenizer {
        pub fn from_path(path: impl AsRef<Path>) -> Result<Self> {
            let path = CString::new(path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let raw = unsafe { delarocha_tokenizer_new(path.as_ptr()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw })
        }

        pub fn from_raw_paths(
            lex_path: impl AsRef<Path>,
            matrix_path: impl AsRef<Path>,
            char_path: impl AsRef<Path>,
            unk_path: impl AsRef<Path>,
        ) -> Result<Self> {
            let lex_path =
                CString::new(lex_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let matrix_path = CString::new(
                matrix_path
                    .as_ref()
                    .as_os_str()
                    .to_string_lossy()
                    .as_bytes(),
            )?;
            let char_path =
                CString::new(char_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let unk_path =
                CString::new(unk_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let raw = unsafe {
                delarocha_tokenizer_new_raw(
                    lex_path.as_ptr(),
                    matrix_path.as_ptr(),
                    char_path.as_ptr(),
                    unk_path.as_ptr(),
                )
            };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw })
        }

        pub fn count_only_from_raw_paths(
            lex_path: impl AsRef<Path>,
            matrix_path: impl AsRef<Path>,
            char_path: impl AsRef<Path>,
            unk_path: impl AsRef<Path>,
        ) -> Result<Self> {
            let lex_path =
                CString::new(lex_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let matrix_path = CString::new(
                matrix_path
                    .as_ref()
                    .as_os_str()
                    .to_string_lossy()
                    .as_bytes(),
            )?;
            let char_path =
                CString::new(char_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let unk_path =
                CString::new(unk_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let raw = unsafe {
                delarocha_tokenizer_new_raw_count_only(
                    lex_path.as_ptr(),
                    matrix_path.as_ptr(),
                    char_path.as_ptr(),
                    unk_path.as_ptr(),
                )
            };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw })
        }

        pub fn from_binary_path(path: impl AsRef<Path>) -> Result<Self> {
            let path = CString::new(path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let raw = unsafe { delarocha_tokenizer_new_binary(path.as_ptr()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw })
        }

        pub fn from_binary_bytes(bytes: &[u8]) -> Result<Self> {
            // The native loader copies dictionary data into Zig-owned storage,
            // so the caller may drop the byte slice after construction.
            let raw = unsafe { delarocha_tokenizer_new_binary_bytes(bytes.as_ptr(), bytes.len()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw })
        }

        pub fn count_only_from_binary_path(path: impl AsRef<Path>) -> Result<Self> {
            let path = CString::new(path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let raw = unsafe { delarocha_tokenizer_new_binary_count_only(path.as_ptr()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw })
        }

        pub fn write_binary_from_raw_paths(
            lex_path: impl AsRef<Path>,
            matrix_path: impl AsRef<Path>,
            char_path: impl AsRef<Path>,
            unk_path: impl AsRef<Path>,
            output_path: impl AsRef<Path>,
        ) -> Result<()> {
            let lex_path =
                CString::new(lex_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let matrix_path = CString::new(
                matrix_path
                    .as_ref()
                    .as_os_str()
                    .to_string_lossy()
                    .as_bytes(),
            )?;
            let char_path =
                CString::new(char_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let unk_path =
                CString::new(unk_path.as_ref().as_os_str().to_string_lossy().as_bytes())?;
            let output_path = CString::new(
                output_path
                    .as_ref()
                    .as_os_str()
                    .to_string_lossy()
                    .as_bytes(),
            )?;
            let status = unsafe {
                delarocha_dictionary_write_binary(
                    lex_path.as_ptr(),
                    matrix_path.as_ptr(),
                    char_path.as_ptr(),
                    unk_path.as_ptr(),
                    output_path.as_ptr(),
                )
            };
            if status != 0 {
                return Err(last_error());
            }
            Ok(())
        }

        pub fn create_worker(&self) -> Result<ZigWorker<'_>> {
            let raw = unsafe { delarocha_worker_new(self.raw.as_ptr()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(ZigWorker {
                raw,
                _tokenizer: PhantomData,
            })
        }
    }

    impl Drop for ZigTokenizer {
        fn drop(&mut self) {
            unsafe { delarocha_tokenizer_free(self.raw.as_ptr()) };
        }
    }

    impl ZigWorker<'_> {
        pub fn tokenize_raw(&mut self, input: &str) -> Result<usize> {
            // Use the byte-oriented entry point so inputs containing NUL bytes
            // remain valid and no temporary CString allocation is required.
            let status =
                unsafe { delarocha_tokenize_bytes(self.raw.as_ptr(), input.as_ptr(), input.len()) };
            if status != 0 {
                return Err(last_error());
            }
            Ok(unsafe { delarocha_token_count(self.raw.as_ptr()) })
        }

        pub fn copy_token_spans(
            &self,
            starts: &mut [usize],
            ends: &mut [usize],
            word_ids: &mut [u32],
        ) -> Result<usize> {
            let cap = starts.len().min(ends.len()).min(word_ids.len());
            let copied = unsafe {
                delarocha_tokens_copy_spans(
                    self.raw.as_ptr(),
                    starts.as_mut_ptr(),
                    ends.as_mut_ptr(),
                    word_ids.as_mut_ptr(),
                    cap,
                )
            };
            if copied == usize::MAX {
                return Err(last_error());
            }
            Ok(copied)
        }

        pub fn token_feature(&self, index: usize) -> &str {
            let feature_ptr = unsafe { delarocha_token_feature(self.raw.as_ptr(), index) };
            if feature_ptr.is_null() {
                ""
            } else {
                unsafe { CStr::from_ptr(feature_ptr) }
                    .to_str()
                    .unwrap_or_default()
            }
        }

        pub fn tokenize(&mut self, input: &str) -> Result<Vec<Token>> {
            let input_c = CString::new(input)?;
            let status = unsafe { delarocha_tokenize(self.raw.as_ptr(), input_c.as_ptr()) };
            if status != 0 {
                return Err(last_error());
            }

            let count = unsafe { delarocha_token_count(self.raw.as_ptr()) };
            let mut tokens = Vec::with_capacity(count);
            for index in 0..count {
                let start = unsafe { delarocha_token_surface_start(self.raw.as_ptr(), index) };
                let end = unsafe { delarocha_token_surface_end(self.raw.as_ptr(), index) };
                let word_id = unsafe { delarocha_token_word_id(self.raw.as_ptr(), index) };
                let feature_ptr = unsafe { delarocha_token_feature(self.raw.as_ptr(), index) };
                let feature = if feature_ptr.is_null() {
                    ""
                } else {
                    unsafe { CStr::from_ptr(feature_ptr) }
                        .to_str()
                        .unwrap_or_default()
                };
                tokens.push(Token {
                    surface: input[start..end].to_owned(),
                    start,
                    end,
                    start_char: input[..start].chars().count(),
                    end_char: input[..end].chars().count(),
                    word_id,
                    feature: feature.to_owned(),
                    total_cost: 0,
                });
            }
            Ok(tokens)
        }

        pub fn tokenize_count(&mut self, input: &str) -> Result<usize> {
            let count = unsafe {
                delarocha_tokenize_count_bytes_nonnull(
                    self.raw.as_ptr(),
                    input.as_ptr(),
                    input.len(),
                )
            };
            if count == usize::MAX {
                return Err(last_error());
            }
            Ok(count)
        }

        #[inline(always)]
        pub fn tokenize_count_assume_valid(&mut self, input: &str) -> usize {
            // Benchmark and trusted hot-loop helper. The safe API above keeps
            // the sentinel check for callers that need error reporting.
            unsafe {
                delarocha_tokenize_count_bytes_nonnull(
                    self.raw.as_ptr(),
                    input.as_ptr(),
                    input.len(),
                )
            }
        }

        pub fn tokenize_spans(&mut self, input: &str) -> Result<Vec<ZigTokenSpan>> {
            let status =
                unsafe { delarocha_tokenize_bytes(self.raw.as_ptr(), input.as_ptr(), input.len()) };
            if status != 0 {
                return Err(last_error());
            }

            let count = unsafe { delarocha_token_count(self.raw.as_ptr()) };
            let mut starts = vec![0; count];
            let mut ends = vec![0; count];
            let mut word_ids = vec![0; count];
            let copied = unsafe {
                delarocha_tokens_copy_spans(
                    self.raw.as_ptr(),
                    starts.as_mut_ptr(),
                    ends.as_mut_ptr(),
                    word_ids.as_mut_ptr(),
                    count,
                )
            };
            if copied == usize::MAX {
                return Err(last_error());
            }
            Ok((0..copied)
                .map(|index| ZigTokenSpan {
                    start: starts[index],
                    end: ends[index],
                    word_id: word_ids[index],
                })
                .collect())
        }

        pub fn tokenize_count_batch(&mut self, batch: &ZigBatch<'_>) -> Result<usize> {
            let count = unsafe {
                delarocha_tokenize_count_batch_nonnull(
                    self.raw.as_ptr(),
                    batch.ptrs.as_ptr(),
                    batch.lens.as_ptr(),
                    batch.ptrs.len(),
                )
            };
            if count == usize::MAX {
                return Err(last_error());
            }
            Ok(count)
        }

        #[inline(always)]
        pub fn tokenize_count_batch_assume_valid(&mut self, batch: &ZigBatch<'_>) -> usize {
            // Batch variant of the trusted count-only helper. It mirrors the
            // non-null Zig export and avoids per-iteration Result handling.
            unsafe {
                delarocha_tokenize_count_batch_nonnull(
                    self.raw.as_ptr(),
                    batch.ptrs.as_ptr(),
                    batch.lens.as_ptr(),
                    batch.ptrs.len(),
                )
            }
        }
    }

    impl Drop for ZigWorker<'_> {
        fn drop(&mut self) {
            unsafe { delarocha_worker_free(self.raw.as_ptr()) };
        }
    }

    fn last_error() -> Error {
        let ptr = unsafe { delarocha_last_error() };
        if ptr.is_null() {
            return Error::Tokenization("unknown Zig FFI error".into());
        }
        Error::Tokenization(
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }
}
