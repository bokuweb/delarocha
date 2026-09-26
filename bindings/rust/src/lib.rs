use std::cmp::Ordering;
use std::ffi::NulError;
#[cfg(feature = "vibrato-system")]
use std::io::BufReader;
use std::io::Read;
use std::marker::PhantomData;
use std::ops::Range;
#[cfg(feature = "vibrato-system")]
use std::path::Path;
use std::sync::Arc;
#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
use wasm_bindgen::prelude::*;

const UNKNOWN_WORD_BASE: u32 = 1 << 31;
const USER_WORD_BASE: u32 = 1 << 30;
const INVALID_LATTICE_INDEX: u32 = u32::MAX;

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
    entry_index: PrefixIndex,
    user_entries: Vec<Entry>,
    user_entry_index: PrefixIndex,
    matrix: ConnectionMatrix,
    char_property: CharProperty,
    unk_entries: Vec<UnkEntry>,
    unk_index: Vec<Vec<usize>>,
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
    range_bmp: Vec<usize>,
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
            entry_index: PrefixIndex::build(&entries),
            entries,
            user_entry_index: PrefixIndex::default(),
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
            unk_index: vec![vec![0]],
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
        let unk_index = build_unk_index(char_property.categories.len(), &unk_entries);

        Ok(Dictionary {
            entry_index: PrefixIndex::build(&entries),
            entries,
            user_entry_index: PrefixIndex::default(),
            user_entries: Vec::new(),
            matrix,
            char_property,
            unk_entries,
            unk_index,
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
        self.user_entry_index = PrefixIndex::build(&self.user_entries);
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
    #[inline]
    fn row(&self, left_id: u16) -> Option<&[i16]> {
        let left = usize::from(left_id);
        (left < self.left_size).then(|| {
            let start = left * self.right_size;
            &self.costs[start..start + self.right_size]
        })
    }

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
            range_bmp: build_range_bmp(&[]),
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
        property.range_bmp = build_range_bmp(&property.ranges);
        Ok(property)
    }

    fn category_id(&self, name: &str) -> Option<usize> {
        self.categories
            .iter()
            .position(|category| category.name == name)
    }

    fn category_for(&self, ch: char) -> CharInfo<'_> {
        let cp = u32::from(ch);
        let range = if cp < 0x10000 {
            self.range_bmp
                .get(cp as usize)
                .and_then(|&index| self.ranges.get(index))
        } else {
            self.ranges
                .iter()
                .rev()
                .find(|range| range.start <= cp && cp < range.end)
        };
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
    dictionary: Arc<Dictionary>,
    ignore_space_category: Option<usize>,
    max_grouping_len: Option<usize>,
}

impl Tokenizer {
    pub fn new(dictionary: Dictionary) -> Self {
        Self {
            dictionary: Arc::new(dictionary),
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

    /// Returns a tokenizer with the given options that shares this
    /// tokenizer's dictionary instead of copying it.
    #[cfg(any(test, all(feature = "wasm", target_arch = "wasm32")))]
    fn configured(&self, ignore_space: bool, max_grouping_len: usize) -> Result<Self> {
        Ok(Self {
            dictionary: Arc::clone(&self.dictionary),
            ignore_space_category: None,
            max_grouping_len: None,
        }
        .ignore_space(ignore_space)?
        .max_grouping_len(max_grouping_len))
    }

    pub fn tokenize(&self, input: &str) -> Result<Vec<Token>> {
        let mut worker = self.create_worker();
        worker.tokenize(input).map(ToOwned::to_owned)
    }

    pub fn tokenize_count(&self, input: &str) -> Result<usize> {
        let mut worker = self.create_worker();
        worker.tokenize_count(input)
    }

    pub fn create_worker(&self) -> Worker<'_> {
        self.create_owned_worker()
    }

    fn create_owned_worker(&self) -> Worker<'static> {
        Worker {
            dictionary: Arc::clone(&self.dictionary),
            ignore_space_category: self.ignore_space_category,
            max_grouping_len: self.max_grouping_len,
            nodes: Vec::new(),
            ends: Vec::new(),
            end_links: Vec::new(),
            tokens: Vec::new(),
            unknown_group_cache: None,
            matches: Vec::new(),
            _dictionary_lifetime: PhantomData,
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

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
#[wasm_bindgen]
#[derive(Debug)]
pub struct WasmTokenizer {
    session: TokenizerSession,
}

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
#[wasm_bindgen]
impl WasmTokenizer {
    #[wasm_bindgen(constructor)]
    pub fn new() -> std::result::Result<WasmTokenizer, JsValue> {
        let dictionary = build_fixture_dictionary().map_err(js_error)?;
        Ok(Self {
            session: TokenizerSession::new(dictionary, false, 24).map_err(js_error)?,
        })
    }

    #[wasm_bindgen(js_name = setOptions)]
    pub fn set_options(
        &mut self,
        ignore_space: bool,
        max_grouping_len: usize,
    ) -> std::result::Result<(), JsValue> {
        self.session
            .set_options(ignore_space, max_grouping_len)
            .map_err(js_error)
    }

    #[wasm_bindgen(js_name = resetDictionary)]
    pub fn reset_dictionary(
        &mut self,
        lexicon_csv: &str,
        matrix_def: &str,
        char_def: &str,
        unk_def: &str,
    ) -> std::result::Result<(), JsValue> {
        let dictionary = SystemDictionaryBuilder::from_readers(
            lexicon_csv.as_bytes(),
            matrix_def.as_bytes(),
            char_def.as_bytes(),
            unk_def.as_bytes(),
        )
        .map_err(js_error)?;
        self.session.reset_dictionary(dictionary).map_err(js_error)
    }

    #[wasm_bindgen(js_name = resetFixtureDictionary)]
    pub fn reset_fixture_dictionary(&mut self) -> std::result::Result<(), JsValue> {
        self.session
            .reset_dictionary(build_fixture_dictionary().map_err(js_error)?)
            .map_err(js_error)
    }

    #[wasm_bindgen(js_name = tokenizeJson)]
    pub fn tokenize_json(&mut self, input: &str) -> std::result::Result<String, JsValue> {
        let tokens = self.session.tokenize(input).map_err(js_error)?;
        Ok(tokens_to_json(tokens))
    }

    #[wasm_bindgen(js_name = tokenizeWakati)]
    pub fn tokenize_wakati(&mut self, input: &str) -> std::result::Result<String, JsValue> {
        let tokens = self.session.tokenize(input).map_err(js_error)?;
        Ok(tokens_to_wakati(tokens))
    }

    #[wasm_bindgen(js_name = tokenizeCount)]
    pub fn tokenize_count(&mut self, input: &str) -> std::result::Result<usize, JsValue> {
        self.session.tokenize_count(input).map_err(js_error)
    }
}

/// Long-lived tokenizer state behind [`WasmTokenizer`].
///
/// The dictionary, tokenizer and worker are built once and only rebuilt when
/// the options or the dictionary actually change. The tokens of the last
/// input are kept so that consecutive calls for the same input (the
/// playground asks for JSON and wakati output of every edit) run the lattice
/// once.
#[cfg(any(test, all(feature = "wasm", target_arch = "wasm32")))]
#[derive(Debug)]
struct TokenizerSession {
    tokenizer: Tokenizer,
    worker: Worker<'static>,
    ignore_space: bool,
    max_grouping_len: usize,
    cached_input: String,
    cache_valid: bool,
}

#[cfg(any(test, all(feature = "wasm", target_arch = "wasm32")))]
impl TokenizerSession {
    fn new(dictionary: Dictionary, ignore_space: bool, max_grouping_len: usize) -> Result<Self> {
        let tokenizer = Tokenizer::new(dictionary).configured(ignore_space, max_grouping_len)?;
        Ok(Self {
            worker: tokenizer.create_owned_worker(),
            tokenizer,
            ignore_space,
            max_grouping_len,
            cached_input: String::new(),
            cache_valid: false,
        })
    }

    fn set_options(&mut self, ignore_space: bool, max_grouping_len: usize) -> Result<()> {
        if ignore_space == self.ignore_space && max_grouping_len == self.max_grouping_len {
            return Ok(());
        }
        let tokenizer = self.tokenizer.configured(ignore_space, max_grouping_len)?;
        self.install(tokenizer);
        self.ignore_space = ignore_space;
        self.max_grouping_len = max_grouping_len;
        Ok(())
    }

    fn reset_dictionary(&mut self, dictionary: Dictionary) -> Result<()> {
        let tokenizer =
            Tokenizer::new(dictionary).configured(self.ignore_space, self.max_grouping_len)?;
        self.install(tokenizer);
        Ok(())
    }

    fn install(&mut self, tokenizer: Tokenizer) {
        self.worker = tokenizer.create_owned_worker();
        self.tokenizer = tokenizer;
        self.cache_valid = false;
    }

    fn tokenize(&mut self, input: &str) -> Result<&[Token]> {
        if !(self.cache_valid && self.cached_input == input) {
            self.cache_valid = false;
            self.worker.tokenize(input)?;
            self.cached_input.clear();
            self.cached_input.push_str(input);
            self.cache_valid = true;
        }
        Ok(&self.worker.tokens)
    }

    fn tokenize_count(&mut self, input: &str) -> Result<usize> {
        self.cache_valid = false;
        self.worker.tokenize_count(input)
    }
}

#[cfg(any(test, all(feature = "wasm", target_arch = "wasm32")))]
fn tokens_to_wakati(tokens: &[Token]) -> String {
    let mut wakati = String::new();
    for (i, token) in tokens.iter().enumerate() {
        if i != 0 {
            wakati.push(' ');
        }
        wakati.push_str(&token.surface);
    }
    wakati
}

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
fn build_fixture_dictionary() -> Result<Dictionary> {
    SystemDictionaryBuilder::from_readers(
        WASM_PLAYGROUND_LEX.as_bytes(),
        WASM_PLAYGROUND_MATRIX.as_bytes(),
        WASM_PLAYGROUND_CHAR.as_bytes(),
        WASM_PLAYGROUND_UNK.as_bytes(),
    )
}

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
const WASM_PLAYGROUND_LEX: &str = "本,0,0,10,名詞-普通名詞-一般,ホン\n\
と,0,0,1,助詞-格助詞,ト\n\
カレー,0,0,10,名詞-普通名詞-一般,カレー\n";

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
const WASM_PLAYGROUND_MATRIX: &str = "1 1\n0 0 0\n";

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
const WASM_PLAYGROUND_CHAR: &str = "DEFAULT 1 0 1\n\
SPACE 1 1 24\n\
ALPHA 1 1 24\n\
KATAKANA 0 1 24\n\
EMOJI 1 1 1\n\
0x0020 SPACE\n\
0x0041..0x005A ALPHA\n\
0x0061..0x007A ALPHA\n\
0x30A0..0x30FF KATAKANA\n\
0x1F300..0x1FAFF EMOJI\n";

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
const WASM_PLAYGROUND_UNK: &str = "DEFAULT,0,0,10000,*\n\
SPACE,0,0,10000,空白,\n\
ALPHA,0,0,10000,記号-文字,\n\
KATAKANA,0,0,10000,名詞-普通名詞-一般,\n\
EMOJI,0,0,10000,補助記号-一般,\n";

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
fn tokens_to_json(tokens: &[Token]) -> String {
    let mut json = String::from("[");
    for (i, token) in tokens.iter().enumerate() {
        if i != 0 {
            json.push(',');
        }
        json.push_str("{\"surface\":");
        push_json_string(&mut json, &token.surface);
        json.push_str(",\"feature\":");
        push_json_string(&mut json, &token.feature);
        json.push_str(",\"start\":");
        json.push_str(&token.start.to_string());
        json.push_str(",\"end\":");
        json.push_str(&token.end.to_string());
        json.push_str(",\"startChar\":");
        json.push_str(&token.start_char.to_string());
        json.push_str(",\"endChar\":");
        json.push_str(&token.end_char.to_string());
        json.push_str(",\"wordId\":");
        json.push_str(&token.word_id.to_string());
        json.push_str(",\"totalCost\":");
        json.push_str(&token.total_cost.to_string());
        json.push_str(",\"unknown\":");
        json.push_str(if token.is_unknown() { "true" } else { "false" });
        json.push('}');
    }
    json.push(']');
    json
}

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
fn push_json_string(json: &mut String, value: &str) {
    json.push('"');
    for ch in value.chars() {
        match ch {
            '"' => json.push_str("\\\""),
            '\\' => json.push_str("\\\\"),
            '\n' => json.push_str("\\n"),
            '\r' => json.push_str("\\r"),
            '\t' => json.push_str("\\t"),
            '\u{08}' => json.push_str("\\b"),
            '\u{0c}' => json.push_str("\\f"),
            ch if ch <= '\u{1f}' => {
                json.push_str("\\u00");
                let code = ch as u8;
                json.push(char::from_digit(u32::from(code >> 4), 16).expect("hex digit"));
                json.push(char::from_digit(u32::from(code & 0x0f), 16).expect("hex digit"));
            }
            ch => json.push(ch),
        }
    }
    json.push('"');
}

#[cfg(all(feature = "wasm", target_arch = "wasm32"))]
fn js_error(err: Error) -> JsValue {
    JsValue::from_str(&err.to_string())
}

#[derive(Debug)]
pub struct Worker<'dict> {
    dictionary: Arc<Dictionary>,
    ignore_space_category: Option<usize>,
    max_grouping_len: Option<usize>,
    nodes: Vec<Node>,
    ends: Vec<u32>,
    end_links: Vec<EndLink>,
    tokens: Vec<Token>,
    unknown_group_cache: Option<UnknownGroupCache>,
    matches: Vec<u32>,
    _dictionary_lifetime: PhantomData<&'dict Dictionary>,
}

#[derive(Clone, Debug)]
struct Node {
    word_id: u32,
    start: u32,
    end: u32,
    right_id: u16,
    min_cost: i32,
    prev_node: u32,
}

#[derive(Clone, Copy, Debug)]
struct EndLink {
    node: u32,
    next: u32,
}

#[derive(Clone, Copy, Debug)]
struct UnknownGroupCache {
    cursor: usize,
    end: usize,
    remaining: usize,
    category_id: usize,
}

#[derive(Clone, Copy, Debug)]
struct GroupSpan {
    end: usize,
    count: usize,
}

fn narrow_lattice_index(index: usize) -> Result<u32> {
    u32::try_from(index)
        .map_err(|_| Error::Tokenization("input produces too many lattice nodes".into()))
}

impl<'dict> Worker<'dict> {
    pub fn tokenize(&mut self, input: &str) -> Result<&[Token]> {
        let Some(best) = self.build_best_path(input)? else {
            return Ok(&self.tokens);
        };
        self.backtrace(input, best)?;
        Ok(&self.tokens)
    }

    pub fn tokenize_count(&mut self, input: &str) -> Result<usize> {
        let Some(best) = self.build_best_path(input)? else {
            return Ok(0);
        };
        Ok(self.count_path(best))
    }

    fn build_best_path(&mut self, input: &str) -> Result<Option<usize>> {
        let dictionary = Arc::clone(&self.dictionary);
        // Lattice nodes store byte offsets as u32.
        if u32::try_from(input.len()).is_err() {
            return Err(Error::Tokenization("input is too long".into()));
        }
        self.reset(input.len());
        if input.is_empty() {
            return Ok(None);
        }

        self.nodes.push(Node::bos());
        self.push_end_link(0, 0)?;
        let input_bytes = input.as_bytes();

        for begin in char_boundaries(input) {
            if begin == input.len() || self.ends[begin] == INVALID_LATTICE_INDEX {
                continue;
            }
            if let Some(space_category) = self.ignore_space_category {
                let ch = input[begin..]
                    .chars()
                    .next()
                    .ok_or_else(|| Error::Tokenization("missing character at boundary".into()))?;
                let info = dictionary.char_property.category_for(ch);
                if info.category_ids.contains(&space_category) {
                    let end = group_end(input, begin, &self.dictionary.char_property, &info);
                    let mut link = self.ends[begin];
                    while link != INVALID_LATTICE_INDEX {
                        let end_link = self.end_links[link as usize];
                        self.push_end_link(end, end_link.node as usize)?;
                        link = end_link.next;
                    }
                    continue;
                }
            }

            // Candidates are appended in ascending word id order (user entries
            // first) because lattice tie-breaking depends on node order.
            let mut matches = std::mem::take(&mut self.matches);
            let mut emitted = false;
            for (index, entries, word_base) in [
                (
                    &dictionary.user_entry_index,
                    &dictionary.user_entries,
                    USER_WORD_BASE,
                ),
                (&dictionary.entry_index, &dictionary.entries, 0),
            ] {
                matches.clear();
                index.common_prefix_word_ids(&input_bytes[begin..], &mut matches);
                matches.sort_unstable();
                for &word_id in &matches {
                    let entry = &entries[word_id as usize];
                    let result = self.append_best_node(
                        begin,
                        begin + entry.surface.len(),
                        Candidate {
                            word_id: word_base + word_id,
                            left_id: entry.left_id,
                            right_id: entry.right_id,
                            word_cost: entry.word_cost,
                        },
                    );
                    if let Err(err) = result {
                        self.matches = matches;
                        return Err(err);
                    }
                    emitted = true;
                }
            }
            self.matches = matches;

            self.append_unknown_nodes(&dictionary, input, begin, emitted)?;
        }

        let best = EndLinkIter {
            links: &self.end_links,
            next: self.ends[input.len()],
        }
        .map(|link| link.node as usize)
        .min_by(|left, right| compare_node_cost(&self.nodes[*left], &self.nodes[*right]))
        .ok_or_else(|| Error::Tokenization("no path reached the end of input".into()))?;
        Ok(Some(best))
    }

    fn reset(&mut self, len: usize) {
        self.nodes.clear();
        self.tokens.clear();
        self.end_links.clear();
        self.unknown_group_cache = None;
        if self.ends.len() < len + 1 {
            self.ends.resize(len + 1, INVALID_LATTICE_INDEX);
        }
        self.ends[..=len].fill(INVALID_LATTICE_INDEX);
    }

    fn append_best_node(&mut self, begin: usize, end: usize, candidate: Candidate) -> Result<()> {
        let best = self.find_best_prev(begin, candidate)?;
        self.append_best_node_with_best(begin, end, candidate, best)
    }

    fn append_best_node_with_best(
        &mut self,
        begin: usize,
        end: usize,
        candidate: Candidate,
        (prev_node, min_cost): (usize, i32),
    ) -> Result<()> {
        let index = self.nodes.len();
        self.nodes.push(Node {
            word_id: candidate.word_id,
            start: begin as u32,
            end: end as u32,
            right_id: candidate.right_id,
            min_cost,
            prev_node: narrow_lattice_index(prev_node)?,
        });
        self.push_end_link(end, index)?;
        Ok(())
    }

    fn push_end_link(&mut self, end: usize, node: usize) -> Result<()> {
        let link = self.end_links.len();
        self.end_links.push(EndLink {
            node: narrow_lattice_index(node)?,
            next: self.ends[end],
        });
        self.ends[end] = narrow_lattice_index(link)?;
        Ok(())
    }

    fn append_unknown_nodes(
        &mut self,
        dictionary: &Dictionary,
        input: &str,
        begin: usize,
        has_matched: bool,
    ) -> Result<()> {
        let ch = input[begin..]
            .chars()
            .next()
            .ok_or_else(|| Error::Tokenization("missing character at unknown boundary".into()))?;
        let info = dictionary.char_property.category_for(ch);
        if has_matched && !info.category.invoke {
            return Ok(());
        }

        let mut emitted = false;
        let first_end = begin + ch.len_utf8();
        let group_span = if !info.category.group {
            if info.category.length == 0 {
                GroupSpan {
                    end: first_end,
                    count: 0,
                }
            } else {
                group_span_after_first(
                    input,
                    first_end,
                    &dictionary.char_property,
                    &info,
                    Some(info.category.length),
                )
            }
        } else if let Some(max) = self.max_grouping_len {
            group_span_after_first(
                input,
                first_end,
                &dictionary.char_property,
                &info,
                Some(info.category.length.max(max.saturating_add(2))),
            )
        } else {
            self.cached_group_span(dictionary, input, begin, first_end, &info)
        };
        let group_end = group_span.end;
        let group_len = group_span.count;
        let max_len = info.category.length.min(group_len);
        if max_len <= 8 {
            for &unk_id in &dictionary.unk_index[info.base_id] {
                let unk = &dictionary.unk_entries[unk_id];
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

                for len in 1..=max_len {
                    if grouped && len == group_len {
                        continue;
                    }
                    self.append_best_node(
                        begin,
                        nth_char_boundary(input, begin, len)?,
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
        } else {
            emitted = self
                .append_long_unknown_nodes(dictionary, input, begin, &info, group_span, max_len)?;
        }

        if !has_matched && !emitted {
            let end = next_char_boundary(input, begin)?;
            let fallback = dictionary.unk_index[info.base_id]
                .first()
                .map(|&unk_id| (unk_id, &dictionary.unk_entries[unk_id]));
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

    #[inline(never)]
    fn append_long_unknown_nodes(
        &mut self,
        dictionary: &Dictionary,
        input: &str,
        begin: usize,
        info: &CharInfo<'_>,
        group_span: GroupSpan,
        max_len: usize,
    ) -> Result<bool> {
        let mut emitted = false;
        for &unk_id in &dictionary.unk_index[info.base_id] {
            let unk = &dictionary.unk_entries[unk_id];
            let grouped = info.category.group
                && self
                    .max_grouping_len
                    .is_none_or(|max| group_span.count.saturating_sub(1) <= max);
            let candidate = Candidate {
                word_id: UNKNOWN_WORD_BASE + unk_id as u32,
                left_id: unk.left_id,
                right_id: unk.right_id,
                word_cost: unk.word_cost,
            };
            let best = self.find_best_prev(begin, candidate)?;
            if grouped {
                self.append_best_node_with_best(begin, group_span.end, candidate, best)?;
                emitted = true;
            }

            let mut end = begin;
            for len in 1..=max_len {
                end = next_char_boundary(input, end)?;
                if grouped && len == group_span.count {
                    continue;
                }
                self.append_best_node_with_best(begin, end, candidate, best)?;
                emitted = true;
            }
        }
        Ok(emitted)
    }

    fn cached_group_span(
        &mut self,
        dictionary: &Dictionary,
        input: &str,
        begin: usize,
        first_end: usize,
        info: &CharInfo<'_>,
    ) -> GroupSpan {
        if let [category_id] = info.category_ids
            && let Some(cache) = &mut self.unknown_group_cache
            && cache.category_id == *category_id
            && begin >= cache.cursor
            && begin < cache.end
        {
            while cache.cursor < begin {
                let Some(ch) = input[cache.cursor..].chars().next() else {
                    break;
                };
                cache.cursor += ch.len_utf8();
                cache.remaining -= 1;
            }
            if cache.cursor == begin {
                return GroupSpan {
                    end: cache.end,
                    count: cache.remaining,
                };
            }
        }

        let span = group_span_after_first(input, first_end, &dictionary.char_property, info, None);
        self.unknown_group_cache = match info.category_ids {
            [category_id] => Some(UnknownGroupCache {
                cursor: begin,
                end: span.end,
                remaining: span.count,
                category_id: *category_id,
            }),
            _ => None,
        };
        span
    }

    fn find_best_prev(&self, begin: usize, candidate: Candidate) -> Result<(usize, i32)> {
        let matrix_row = self
            .dictionary
            .matrix
            .row(candidate.left_id)
            .ok_or_else(|| Error::Tokenization("candidate has invalid left id".into()))?;
        let first_link = self.ends[begin];
        if first_link == INVALID_LATTICE_INDEX {
            return Err(Error::Tokenization("candidate has no previous node".into()));
        }
        let first = self.end_links[first_link as usize];
        let first_node = first.node as usize;
        let first_prev = &self.nodes[first_node];
        let mut best_index = first_node;
        let mut best_cost = first_prev.min_cost
            + i32::from(matrix_row[usize::from(first_prev.right_id)])
            + candidate.word_cost;
        if first.next == INVALID_LATTICE_INDEX {
            return Ok((best_index, best_cost));
        }

        let mut next = first.next;
        while next != INVALID_LATTICE_INDEX {
            let link = self.end_links[next as usize];
            let node_index = link.node as usize;
            let prev = &self.nodes[node_index];
            let cost = prev.min_cost
                + i32::from(matrix_row[usize::from(prev.right_id)])
                + candidate.word_cost;
            if cost < best_cost || (cost == best_cost && node_index > best_index) {
                best_index = node_index;
                best_cost = cost;
            }
            next = link.next;
        }
        Ok((best_index, best_cost))
    }

    fn count_path(&self, mut index: usize) -> usize {
        let mut count = 0usize;
        while self.nodes[index].prev_node != INVALID_LATTICE_INDEX {
            count += 1;
            index = self.nodes[index].prev_node as usize;
        }
        count
    }

    fn backtrace(&mut self, input: &str, mut index: usize) -> Result<()> {
        while self.nodes[index].prev_node != INVALID_LATTICE_INDEX {
            let node = &self.nodes[index];
            let (surface, feature) = if node.word_id >= UNKNOWN_WORD_BASE {
                let unk_index = (node.word_id - UNKNOWN_WORD_BASE) as usize;
                let feature = self
                    .dictionary
                    .unk_entries
                    .get(unk_index)
                    .map_or("UNK", |entry| entry.feature.as_str());
                (&input[node.start as usize..node.end as usize], feature)
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
            self.tokens.push(Token {
                surface: surface.to_owned(),
                start: node.start as usize,
                end: node.end as usize,
                start_char: 0,
                end_char: 0,
                word_id: node.word_id,
                feature: feature.to_owned(),
                total_cost: node.min_cost,
            });
            index = self.nodes[index].prev_node as usize;
        }
        self.tokens.reverse();
        let mut byte_cursor = 0;
        let mut char_cursor = 0;
        for token in &mut self.tokens {
            char_cursor += input[byte_cursor..token.start].chars().count();
            token.start_char = char_cursor;
            char_cursor += input[token.start..token.end].chars().count();
            token.end_char = char_cursor;
            byte_cursor = token.end;
        }
        Ok(())
    }
}

struct EndLinkIter<'a> {
    links: &'a [EndLink],
    next: u32,
}

impl<'a> Iterator for EndLinkIter<'a> {
    type Item = EndLink;

    fn next(&mut self) -> Option<Self::Item> {
        if self.next == INVALID_LATTICE_INDEX {
            return None;
        }
        let link = self.links[self.next as usize];
        self.next = link.next;
        Some(link)
    }
}

impl Node {
    fn bos() -> Self {
        Self {
            word_id: u32::MAX,
            start: 0,
            end: 0,
            right_id: 0,
            min_cost: 0,
            prev_node: INVALID_LATTICE_INDEX,
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

fn group_span_after_first(
    input: &str,
    first_end: usize,
    char_property: &CharProperty,
    start_info: &CharInfo<'_>,
    max_count: Option<usize>,
) -> GroupSpan {
    let mut end = first_end;
    let mut count = 1usize;
    while end < input.len() && max_count.is_none_or(|max| count < max) {
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
        count += 1;
    }
    GroupSpan { end, count }
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

/// Common-prefix search index over entry surfaces.
///
/// Distinct surfaces are sorted bytewise and stored back to back in `keys`.
/// A lookup narrows the sorted key range one input byte at a time with two
/// binary searches, so the work per lattice position is proportional to the
/// matched depth times `log(keys)` instead of the number of entries sharing
/// the first byte.
#[derive(Clone, Debug)]
struct PrefixIndex {
    /// Concatenated distinct surfaces in sorted order.
    keys: Vec<u8>,
    /// `keys[key_offsets[k]..key_offsets[k + 1]]` is the k-th surface.
    key_offsets: Vec<u32>,
    /// `word_ids[id_offsets[k]..id_offsets[k + 1]]` are the entries of the
    /// k-th surface, in ascending word id order.
    id_offsets: Vec<u32>,
    word_ids: Vec<u32>,
    /// Key range for each leading byte: `first_byte[b]..first_byte[b + 1]`.
    first_byte: Box<[u32; 257]>,
}

impl Default for PrefixIndex {
    fn default() -> Self {
        Self {
            keys: Vec::new(),
            key_offsets: vec![0],
            id_offsets: vec![0],
            word_ids: Vec::new(),
            first_byte: Box::new([0; 257]),
        }
    }
}

impl PrefixIndex {
    fn build(entries: &[Entry]) -> Self {
        let mut order: Vec<(&[u8], u32)> = entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| !entry.surface.is_empty())
            .map(|(word_id, entry)| (entry.surface.as_bytes(), word_id as u32))
            .collect();
        // (surface, word_id) pairs are unique, so an unstable sort is
        // deterministic and keeps word ids ascending within a surface.
        order.sort_unstable();

        let mut index = Self::default();
        index.word_ids.reserve_exact(order.len());
        let mut previous: Option<&[u8]> = None;
        for (surface, word_id) in order {
            if previous != Some(surface) {
                if previous.is_some() {
                    index.id_offsets.push(index.word_ids.len() as u32);
                }
                index.keys.extend_from_slice(surface);
                index.key_offsets.push(index.keys.len() as u32);
                index.first_byte[usize::from(surface[0]) + 1] += 1;
                previous = Some(surface);
            }
            index.word_ids.push(word_id);
        }
        if previous.is_some() {
            index.id_offsets.push(index.word_ids.len() as u32);
        }
        for byte in 0..256 {
            index.first_byte[byte + 1] += index.first_byte[byte];
        }
        index
    }

    #[inline]
    fn key(&self, key: usize) -> &[u8] {
        &self.keys[self.key_offsets[key] as usize..self.key_offsets[key + 1] as usize]
    }

    /// First key in `lo..hi` whose byte at `depth` is not less than `byte`.
    /// Every key in the range must be longer than `depth`.
    #[inline]
    fn lower_bound(&self, mut lo: usize, mut hi: usize, depth: usize, byte: u8) -> usize {
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.keys[self.key_offsets[mid] as usize + depth] < byte {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// Appends the word ids of every surface that is a prefix of `input`.
    fn common_prefix_word_ids(&self, input: &[u8], out: &mut Vec<u32>) {
        let Some(&first) = input.first() else {
            return;
        };
        let mut lo = self.first_byte[usize::from(first)] as usize;
        let mut hi = self.first_byte[usize::from(first) + 1] as usize;
        let mut depth = 1;
        while lo < hi {
            // Every key in lo..hi starts with input[..depth]; the one equal to
            // it, if any, sorts first.
            if self.key(lo).len() == depth {
                out.extend_from_slice(
                    &self.word_ids[self.id_offsets[lo] as usize..self.id_offsets[lo + 1] as usize],
                );
                lo += 1;
            }
            if depth == input.len() || lo == hi {
                break;
            }
            let byte = input[depth];
            lo = self.lower_bound(lo, hi, depth, byte);
            hi = match byte.checked_add(1) {
                Some(next) => self.lower_bound(lo, hi, depth, next),
                None => hi,
            };
            depth += 1;
        }
    }
}

const INVALID_CHAR_RANGE: usize = usize::MAX;

fn build_range_bmp(ranges: &[CharRange]) -> Vec<usize> {
    let mut range_bmp = vec![INVALID_CHAR_RANGE; 0x10000];
    for (range_index, range) in ranges.iter().enumerate() {
        if range.start >= 0x10000 {
            continue;
        }
        let start = range.start as usize;
        let end = range.end.min(0x10000) as usize;
        range_bmp[start..end].fill(range_index);
    }
    range_bmp
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

fn build_unk_index(category_count: usize, entries: &[UnkEntry]) -> Vec<Vec<usize>> {
    let mut index = vec![Vec::new(); category_count];
    for (unk_id, entry) in entries.iter().enumerate() {
        index[entry.category_id].push(unk_id);
    }
    index
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
    use std::fs::File;
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
        fn delarocha_tokenizer_new_binary_bytes(
            bytes_ptr: *const u8,
            bytes_len: usize,
        ) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_binary_borrowed_bytes(
            bytes_ptr: *const u8,
            bytes_len: usize,
        ) -> *mut RawTokenizer;
        fn delarocha_tokenizer_new_binary_borrowed_bytes_count_only(
            bytes_ptr: *const u8,
            bytes_len: usize,
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
        fn delarocha_tokens_copy_spans(
            worker: *const RawWorker,
            starts: *mut usize,
            ends: *mut usize,
            word_ids: *mut u32,
            cap: usize,
        ) -> usize;
        fn delarocha_tokens_copy_metadata(
            worker: *const RawWorker,
            starts: *mut u32,
            ends: *mut u32,
            word_ids: *mut u32,
            feature_ptrs: *mut *const u8,
            feature_lens: *mut usize,
            cap: usize,
        ) -> usize;
        fn delarocha_token_feature(
            worker: *const RawWorker,
            index: usize,
        ) -> *const std::ffi::c_char;
        fn delarocha_token_feature_len(worker: *const RawWorker, index: usize) -> usize;
        fn delarocha_last_error() -> *const std::ffi::c_char;
    }

    pub struct ZigTokenizer {
        raw: NonNull<RawTokenizer>,
        // Backing storage for tokenizers created from a mapped binary file.
        // The native dictionary borrows slices from it, so it must outlive
        // `raw`: `Drop` frees `raw` first and only then are fields dropped.
        // Workers and token views borrow `&ZigTokenizer`, so they cannot
        // outlive the mapping either.
        _mmap: Option<memmap2::Mmap>,
    }

    pub struct ZigWorker<'tokenizer> {
        raw: NonNull<RawWorker>,
        span_starts: Vec<u32>,
        span_ends: Vec<u32>,
        span_start_chars: Vec<u32>,
        span_end_chars: Vec<u32>,
        span_word_ids: Vec<u32>,
        feature_ptrs: Vec<*const u8>,
        feature_lens: Vec<usize>,
        feature_utf8: FeatureUtf8Cache,
        spare_tokens: Vec<Token>,
        _tokenizer: PhantomData<&'tokenizer ZigTokenizer>,
    }

    // Upper bound on tokens `ZigWorker::tokenize_into` keeps for reuse, so one
    // huge document does not pin its token strings for the worker lifetime.
    const SPARE_TOKEN_LIMIT: usize = 4096;

    /// Per-worker memo of dictionary features already proven to be UTF-8.
    ///
    /// The Zig core returns feature bytes without validating them, and binary
    /// dictionaries may come from untrusted files. Instead of running
    /// `str::from_utf8` on every emitted token (about 11% of the full FFI
    /// tokenize profile), each distinct word id is validated the first time it
    /// appears and remembered in a bitset. Dictionary data is immutable for the
    /// tokenizer lifetime, and the Zig side derives the feature bytes from the
    /// word id alone; compact features also copy the token surface, but the
    /// decoder only copies whole UTF-8 sequences of the (valid UTF-8) input,
    /// so whether a decoded feature is valid still depends on the word id
    /// only. A validated word id therefore stays valid for every later token.
    /// Validating lazily keeps mmap-backed dictionaries from paging in the
    /// whole feature blob at load time.
    #[derive(Default)]
    struct FeatureUtf8Cache {
        known: Vec<u64>,
        unknown: Vec<u64>,
    }

    // Bound the bitset for pathological word ids. Larger ids are still
    // validated, just without memoization.
    const FEATURE_UTF8_CACHE_LIMIT: u32 = 1 << 24;

    impl FeatureUtf8Cache {
        #[inline(always)]
        fn bits(&self, word_id: u32) -> Option<(&[u64], usize)> {
            let (bits, index) = if word_id < USER_WORD_BASE {
                (&self.known, word_id)
            } else if word_id >= UNKNOWN_WORD_BASE {
                (&self.unknown, word_id - UNKNOWN_WORD_BASE)
            } else {
                // User entries are not exposed through the FFI bindings.
                return None;
            };
            (index < FEATURE_UTF8_CACHE_LIMIT).then_some((bits.as_slice(), index as usize))
        }

        /// Fast path: whether `word_id`'s feature was already proven UTF-8.
        #[inline(always)]
        fn is_validated(&self, word_id: u32) -> bool {
            self.bits(word_id).is_some_and(|(bits, index)| {
                bits.get(index / 64)
                    .is_some_and(|word| word & (1u64 << (index % 64)) != 0)
            })
        }

        /// Slow path: validates `bytes`, the feature of `word_id`, and
        /// memoizes success.
        #[cold]
        #[inline(never)]
        fn validate(&mut self, word_id: u32, bytes: &[u8]) -> bool {
            if std::str::from_utf8(bytes).is_err() {
                return false;
            }
            if self.bits(word_id).is_some() {
                let (bits, index) = if word_id >= UNKNOWN_WORD_BASE {
                    (&mut self.unknown, (word_id - UNKNOWN_WORD_BASE) as usize)
                } else {
                    (&mut self.known, word_id as usize)
                };
                let word = index / 64;
                if bits.len() <= word {
                    bits.resize(word + 1, 0);
                }
                bits[word] |= 1u64 << (index % 64);
            }
            true
        }
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

    /// Zero-copy token: `surface` borrows the tokenized input and `feature`
    /// borrows dictionary storage (or, for dictionaries with compact features,
    /// the worker's decoded-feature cache), so producing one allocates nothing.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct ZigTokenView<'a> {
        pub surface: &'a str,
        pub feature: &'a str,
        pub start: usize,
        pub end: usize,
        pub start_char: usize,
        pub end_char: usize,
        pub word_id: u32,
    }

    impl<'a> ZigTokenView<'a> {
        pub fn surface(&self) -> &'a str {
            self.surface
        }

        pub fn feature(&self) -> &'a str {
            self.feature
        }

        pub fn range_byte(&self) -> Range<usize> {
            self.start..self.end
        }

        pub fn range_char(&self) -> Range<usize> {
            self.start_char..self.end_char
        }

        pub fn word_id(&self) -> u32 {
            self.word_id
        }

        pub fn is_unknown(&self) -> bool {
            self.word_id >= UNKNOWN_WORD_BASE
        }

        /// Copies the borrowed strings into an owned [`Token`], matching the
        /// output of [`ZigWorker::tokenize`].
        pub fn to_token(&self) -> Token {
            Token {
                surface: self.surface.to_owned(),
                start: self.start,
                end: self.end,
                start_char: self.start_char,
                end_char: self.end_char,
                word_id: self.word_id,
                feature: self.feature.to_owned(),
                total_cost: 0,
            }
        }
    }

    impl From<ZigTokenView<'_>> for Token {
        fn from(view: ZigTokenView<'_>) -> Self {
            view.to_token()
        }
    }

    /// Token views over the worker's reusable metadata buffers.
    ///
    /// Only [`ZigWorker::tokenize_borrowed_views`] constructs this type, after
    /// `ZigWorker::load_tokens` has checked every span against `input` and
    /// proven every feature slice to be UTF-8. `get` relies on that invariant
    /// to skip per-token validation.
    #[derive(Clone, Copy, Debug)]
    pub struct ZigTokenViews<'a> {
        input: &'a str,
        starts: &'a [u32],
        ends: &'a [u32],
        start_chars: &'a [u32],
        end_chars: &'a [u32],
        word_ids: &'a [u32],
        feature_ptrs: &'a [*const u8],
        feature_lens: &'a [usize],
    }

    impl<'a> ZigTokenViews<'a> {
        pub fn len(&self) -> usize {
            self.starts.len()
        }

        pub fn is_empty(&self) -> bool {
            self.starts.is_empty()
        }

        pub fn get(&self, index: usize) -> Option<ZigTokenView<'a>> {
            if index >= self.len() {
                return None;
            }
            // SAFETY: all metadata slices have the same length (see
            // `tokenize_borrowed_views`), `index` is in bounds, and
            // `load_tokens` validated the span and feature at `index`.
            unsafe { Some(self.get_unchecked(index)) }
        }

        pub fn iter(&self) -> impl ExactSizeIterator<Item = ZigTokenView<'a>> + '_ {
            // SAFETY: `index < self.len()`; see `get`.
            (0..self.len()).map(|index| unsafe { self.get_unchecked(index) })
        }

        /// # Safety
        /// `index` must be less than `self.len()`.
        #[inline]
        unsafe fn get_unchecked(&self, index: usize) -> ZigTokenView<'a> {
            unsafe {
                let start = *self.starts.get_unchecked(index) as usize;
                let end = *self.ends.get_unchecked(index) as usize;
                ZigTokenView {
                    // SAFETY: `load_tokens` checked `start <= end <= input.len()`
                    // and that both offsets are char boundaries of `input`.
                    surface: self.input.get_unchecked(start..end),
                    // SAFETY: `load_tokens` proved these bytes are UTF-8 (or
                    // replaced them with an empty slice); they live in the
                    // tokenizer's immutable dictionary, which outlives 'a.
                    feature: feature_str(
                        *self.feature_ptrs.get_unchecked(index),
                        *self.feature_lens.get_unchecked(index),
                    ),
                    start,
                    end,
                    start_char: *self.start_chars.get_unchecked(index) as usize,
                    end_char: *self.end_chars.get_unchecked(index) as usize,
                    word_id: *self.word_ids.get_unchecked(index),
                }
            }
        }
    }

    /// # Safety
    /// `ptr[..len]` must be valid UTF-8 that stays alive and unmodified for
    /// `'a`, and `ptr` must be non-null when `len > 0`.
    #[inline(always)]
    unsafe fn feature_str<'a>(ptr: *const u8, len: usize) -> &'a str {
        if len == 0 {
            return "";
        }
        unsafe { std::str::from_utf8_unchecked(std::slice::from_raw_parts(ptr, len)) }
    }

    // Counts UTF-8 scalar values by skipping continuation bytes. `bytes` must
    // come from a `str` sliced at char boundaries.
    #[inline(always)]
    fn count_chars(bytes: &[u8]) -> usize {
        bytes.iter().filter(|&&byte| (byte as i8) >= -0x40).count()
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
            Ok(Self { raw, _mmap: None })
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
            Ok(Self { raw, _mmap: None })
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
            Ok(Self { raw, _mmap: None })
        }

        /// Memory-maps a binary dictionary and borrows it for the tokenizer's
        /// lifetime (features, matrix, and trie tables are not copied).
        ///
        /// The file must not be truncated or modified in place while the
        /// tokenizer is alive; replace dictionaries by writing a new file and
        /// renaming it over the old path. Use [`Self::from_binary_bytes`] to
        /// load a private copy instead.
        pub fn from_binary_path(path: impl AsRef<Path>) -> Result<Self> {
            Self::from_mapped_binary_path(path, delarocha_tokenizer_new_binary_borrowed_bytes)
        }

        pub fn from_binary_bytes(bytes: &[u8]) -> Result<Self> {
            // The native loader copies dictionary data into Zig-owned storage,
            // so the caller may drop the byte slice after construction.
            let raw = unsafe { delarocha_tokenizer_new_binary_bytes(bytes.as_ptr(), bytes.len()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self { raw, _mmap: None })
        }

        /// Count-only variant of [`Self::from_binary_path`] with the same
        /// mapping requirements. Full-token data is dropped after loading, and
        /// count tokenization never touches the mapped feature bytes.
        pub fn count_only_from_binary_path(path: impl AsRef<Path>) -> Result<Self> {
            Self::from_mapped_binary_path(
                path,
                delarocha_tokenizer_new_binary_borrowed_bytes_count_only,
            )
        }

        fn from_mapped_binary_path(
            path: impl AsRef<Path>,
            load: unsafe extern "C" fn(*const u8, usize) -> *mut RawTokenizer,
        ) -> Result<Self> {
            let file = File::open(path)?;
            // SAFETY: the mapping is read-only and moved into the returned
            // tokenizer, which frees the native tokenizer (the only holder of
            // pointers into it) before dropping the mapping. Truncation of the
            // file by another process is outside Rust's control; see the
            // public constructors' docs.
            let mmap = unsafe { memmap2::Mmap::map(&file)? };
            let raw = unsafe { load(mmap.as_ptr(), mmap.len()) };
            let raw = NonNull::new(raw).ok_or_else(last_error)?;
            Ok(Self {
                raw,
                _mmap: Some(mmap),
            })
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
                span_starts: Vec::new(),
                span_ends: Vec::new(),
                span_start_chars: Vec::new(),
                span_end_chars: Vec::new(),
                span_word_ids: Vec::new(),
                feature_ptrs: Vec::new(),
                feature_lens: Vec::new(),
                feature_utf8: FeatureUtf8Cache::default(),
                spare_tokens: Vec::new(),
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
            let feature_len = unsafe { delarocha_token_feature_len(self.raw.as_ptr(), index) };
            if feature_ptr.is_null() {
                ""
            } else {
                std::str::from_utf8(unsafe {
                    std::slice::from_raw_parts(feature_ptr.cast::<u8>(), feature_len)
                })
                .unwrap_or_default()
            }
        }

        /// Runs Zig tokenization and copies token metadata into the worker's
        /// reusable buffers. Returns the number of tokens copied. Without
        /// `with_features` only spans and word ids are copied, and the Zig side
        /// skips feature lookup and decoding.
        fn copy_metadata(&mut self, input: &str, with_features: bool) -> Result<usize> {
            let status =
                unsafe { delarocha_tokenize_bytes(self.raw.as_ptr(), input.as_ptr(), input.len()) };
            if status != 0 {
                return Err(last_error());
            }

            let count = unsafe { delarocha_token_count(self.raw.as_ptr()) };
            self.span_starts.resize(count, 0);
            self.span_ends.resize(count, 0);
            self.span_word_ids.resize(count, 0);
            let (feature_ptrs, feature_lens) = if with_features {
                self.feature_ptrs.resize(count, std::ptr::null());
                self.feature_lens.resize(count, 0);
                (
                    self.feature_ptrs.as_mut_ptr(),
                    self.feature_lens.as_mut_ptr(),
                )
            } else {
                (std::ptr::null_mut(), std::ptr::null_mut())
            };
            let copied = unsafe {
                delarocha_tokens_copy_metadata(
                    self.raw.as_ptr(),
                    self.span_starts.as_mut_ptr(),
                    self.span_ends.as_mut_ptr(),
                    self.span_word_ids.as_mut_ptr(),
                    feature_ptrs,
                    feature_lens,
                    count,
                )
            };
            if copied == usize::MAX {
                return Err(last_error());
            }
            Ok(copied)
        }

        /// [`Self::copy_metadata`] plus the checks that let every token
        /// accessor use unchecked `str` construction:
        ///
        /// - each span satisfies `previous_end <= start <= end <= input.len()`
        ///   and both offsets are char boundaries of `input`;
        /// - each feature slice is valid UTF-8 (memoized per word id, see
        ///   [`FeatureUtf8Cache`]); invalid features are replaced with `""`,
        ///   matching the previous `from_utf8(..).unwrap_or_default()`.
        ///
        /// Character offsets are computed in the same forward pass.
        fn load_tokens(&mut self, input: &str) -> Result<usize> {
            let copied = self.copy_metadata(input, true)?;
            self.span_start_chars.resize(copied, 0);
            self.span_end_chars.resize(copied, 0);

            let bytes = input.as_bytes();
            let cache = &mut self.feature_utf8;
            let tokens = self.span_starts[..copied]
                .iter()
                .zip(&self.span_ends[..copied])
                .zip(&self.span_word_ids[..copied])
                .zip(&self.feature_ptrs[..copied])
                .zip(&mut self.feature_lens[..copied])
                .zip(&mut self.span_start_chars[..copied])
                .zip(&mut self.span_end_chars[..copied]);
            let mut previous_byte = 0usize;
            let mut current_char = 0usize;
            for (
                (((((&start, &end), &word_id), &feature_ptr), feature_len), start_char),
                end_char,
            ) in tokens
            {
                let (start, end) = (start as usize, end as usize);
                if previous_byte > start
                    || start > end
                    || !input.is_char_boundary(start)
                    || !input.is_char_boundary(end)
                {
                    return Err(Error::Tokenization(format!(
                        "Zig returned an invalid token span {start}..{end}"
                    )));
                }
                // Token byte ranges are emitted in sentence order. Keep the
                // character cursor moving forward so long inputs do not rescan
                // the whole prefix for every token.
                if previous_byte != start {
                    current_char += count_chars(&bytes[previous_byte..start]);
                }
                *start_char = current_char as u32;
                current_char += count_chars(&bytes[start..end]);
                *end_char = current_char as u32;
                previous_byte = end;

                if *feature_len != 0 && !cache.is_validated(word_id) {
                    // SAFETY: Zig returns a pointer/length pair into the
                    // tokenizer's dictionary, which outlives this worker.
                    let valid = !feature_ptr.is_null()
                        && cache.validate(word_id, unsafe {
                            std::slice::from_raw_parts(feature_ptr, *feature_len)
                        });
                    if !valid {
                        *feature_len = 0;
                    }
                }
            }
            Ok(copied)
        }

        /// # Safety
        /// `index` must be less than the count returned by the preceding
        /// [`Self::load_tokens`] call for `input`.
        #[inline(always)]
        unsafe fn token_parts<'a>(&'a self, input: &'a str, index: usize) -> (&'a str, &'a str) {
            unsafe {
                let start = *self.span_starts.get_unchecked(index) as usize;
                let end = *self.span_ends.get_unchecked(index) as usize;
                (
                    // SAFETY: `load_tokens` checked bounds and char boundaries.
                    input.get_unchecked(start..end),
                    // SAFETY: `load_tokens` validated the feature bytes.
                    feature_str(
                        *self.feature_ptrs.get_unchecked(index),
                        *self.feature_lens.get_unchecked(index),
                    ),
                )
            }
        }

        pub fn tokenize(&mut self, input: &str) -> Result<Vec<Token>> {
            let mut tokens = Vec::new();
            self.tokenize_into(input, &mut tokens)?;
            Ok(tokens)
        }

        /// Owned tokenization into a caller-provided vector.
        ///
        /// Tokens already in `tokens` are overwritten in place, so their
        /// `surface`/`feature` string buffers are reused instead of
        /// reallocated. When a sentence yields fewer tokens, the surplus is
        /// parked in the worker (up to a small bound) for later sentences.
        /// Callers tokenizing many sentences with one vector therefore pay the
        /// two per-token string allocations only while the buffers warm up.
        pub fn tokenize_into(&mut self, input: &str, tokens: &mut Vec<Token>) -> Result<()> {
            let copied = self.load_tokens(input)?;
            if tokens.len() > copied {
                // Park surplus tokens instead of dropping them so a later,
                // longer sentence can reuse their string buffers.
                let room = SPARE_TOKEN_LIMIT.saturating_sub(self.spare_tokens.len());
                let keep_end = tokens.len().min(copied + room);
                self.spare_tokens.extend(tokens.drain(copied..keep_end));
                tokens.truncate(copied);
            }
            tokens.reserve(copied - tokens.len());
            for index in 0..copied {
                if index == tokens.len()
                    && let Some(token) = self.spare_tokens.pop()
                {
                    tokens.push(token);
                }
                // SAFETY: `index < copied`, the `load_tokens` result for `input`.
                let (surface, feature) = unsafe { self.token_parts(input, index) };
                let start = self.span_starts[index] as usize;
                let end = self.span_ends[index] as usize;
                let start_char = self.span_start_chars[index] as usize;
                let end_char = self.span_end_chars[index] as usize;
                let word_id = self.span_word_ids[index];
                let Some(token) = tokens.get_mut(index) else {
                    tokens.push(Token {
                        surface: surface.to_owned(),
                        start,
                        end,
                        start_char,
                        end_char,
                        word_id,
                        feature: feature.to_owned(),
                        total_cost: 0,
                    });
                    continue;
                };
                token.surface.clear();
                token.surface.push_str(surface);
                token.feature.clear();
                token.feature.push_str(feature);
                token.start = start;
                token.end = end;
                token.start_char = start_char;
                token.end_char = end_char;
                token.word_id = word_id;
                token.total_cost = 0;
            }
            Ok(())
        }

        pub fn tokenize_views<'a>(&'a mut self, input: &'a str) -> Result<Vec<ZigTokenView<'a>>> {
            Ok(self.tokenize_borrowed_views(input)?.iter().collect())
        }

        /// Zero-copy tokenization: returns views whose surfaces borrow `input`
        /// and whose features borrow dictionary (or worker) storage. The views live in the
        /// worker's reusable buffers, so steady-state calls allocate nothing.
        /// [`ZigTokenView::to_token`] reproduces [`Self::tokenize`] exactly.
        pub fn tokenize_borrowed_views<'a>(
            &'a mut self,
            input: &'a str,
        ) -> Result<ZigTokenViews<'a>> {
            let copied = self.load_tokens(input)?;
            Ok(ZigTokenViews {
                input,
                starts: &self.span_starts[..copied],
                ends: &self.span_ends[..copied],
                start_chars: &self.span_start_chars[..copied],
                end_chars: &self.span_end_chars[..copied],
                word_ids: &self.span_word_ids[..copied],
                feature_ptrs: &self.feature_ptrs[..copied],
                feature_lens: &self.feature_lens[..copied],
            })
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
            let mut spans = Vec::new();
            self.tokenize_spans_into(input, &mut spans)?;
            Ok(spans)
        }

        /// Like [`Self::tokenize_spans`], but clears and refills `spans` so a
        /// caller tokenizing many sentences can reuse one output allocation.
        pub fn tokenize_spans_into(
            &mut self,
            input: &str,
            spans: &mut Vec<ZigTokenSpan>,
        ) -> Result<()> {
            let copied = self.copy_metadata(input, false)?;
            spans.clear();
            spans.reserve(copied);
            spans.extend(
                self.span_starts[..copied]
                    .iter()
                    .zip(&self.span_ends[..copied])
                    .zip(&self.span_word_ids[..copied])
                    .map(|((&start, &end), &word_id)| ZigTokenSpan {
                        start: start as usize,
                        end: end as usize,
                        word_id,
                    }),
            );
            Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    const LEX_CSV: &str = include_str!("../../../fixtures/vibrato/lex.csv");
    const MATRIX_DEF: &str = include_str!("../../../fixtures/vibrato/matrix.def");
    const CHAR_DEF: &str = include_str!("../../../fixtures/vibrato/char.def");
    const UNK_DEF: &str = include_str!("../../../fixtures/vibrato/unk.def");
    const USER_CSV: &str = include_str!("../../../fixtures/vibrato/user.csv");

    fn fixture_dictionary() -> Dictionary {
        SystemDictionaryBuilder::from_readers(
            LEX_CSV.as_bytes(),
            MATRIX_DEF.as_bytes(),
            CHAR_DEF.as_bytes(),
            UNK_DEF.as_bytes(),
        )
        .expect("fixture dictionary builds")
    }

    fn entry(surface: &str) -> Entry {
        Entry {
            surface: surface.to_owned(),
            left_id: 0,
            right_id: 0,
            word_cost: 0,
            feature: String::new(),
        }
    }

    fn brute_force_matches(entries: &[Entry], input: &[u8]) -> Vec<u32> {
        (0..entries.len() as u32)
            .filter(|&id| {
                let surface = entries[id as usize].surface.as_bytes();
                !surface.is_empty() && input.starts_with(surface)
            })
            .collect()
    }

    fn assert_index_matches_brute_force(entries: &[Entry], inputs: &[&str]) {
        let index = PrefixIndex::build(entries);
        for input in inputs {
            for (begin, _) in input.char_indices() {
                let rest = &input.as_bytes()[begin..];
                let mut found = Vec::new();
                index.common_prefix_word_ids(rest, &mut found);
                found.sort_unstable();
                assert_eq!(
                    found,
                    brute_force_matches(entries, rest),
                    "{:?}",
                    &input[begin..]
                );
            }
        }
    }

    #[test]
    fn prefix_index_matches_linear_scan() {
        let entries: Vec<_> = [
            "東",
            "東京",
            "東京都",
            "東京",
            "",
            "京都",
            "都",
            "a",
            "ab",
            "abc",
            "abd",
            "b",
            "東京",
            "ab",
            "\u{7f}",
            "\u{80}",
            "🍛",
            "🍛カレー",
            "カ",
            "カレー",
            "カレーライス",
        ]
        .into_iter()
        .map(entry)
        .collect();
        assert_index_matches_brute_force(
            &entries,
            &[
                "東京都に行く",
                "abcabdab",
                "🍛カレーライス\u{7f}\u{80}",
                "カレカレー",
                "",
                "x",
            ],
        );
        assert_index_matches_brute_force(&[], &["東京"]);

        let fixture = parse_mecab_entries(LEX_CSV.as_bytes(), "lex.csv").unwrap();
        assert_index_matches_brute_force(&fixture, &["京都東京都に行った", "アイウエオ東京"]);
    }

    #[test]
    fn session_reuses_dictionary_and_matches_fresh_tokenizer() {
        let dictionary = fixture_dictionary()
            .reset_user_lexicon_from_reader(Some(USER_CSV.as_bytes()))
            .unwrap();
        let mut session = TokenizerSession::new(dictionary.clone(), false, 24).unwrap();
        let shared = Arc::clone(&session.tokenizer.dictionary);
        let inputs = [
            "京都東京都に行った",
            "  東京 🍛 アイウエオ",
            "",
            "京都東京都に行った",
        ];

        for (ignore_space, max_grouping_len) in [(false, 24), (false, 24), (true, 0), (true, 2)] {
            session.set_options(ignore_space, max_grouping_len).unwrap();
            assert!(Arc::ptr_eq(&shared, &session.tokenizer.dictionary));
            let fresh = Tokenizer::new(dictionary.clone())
                .ignore_space(ignore_space)
                .unwrap()
                .max_grouping_len(max_grouping_len);
            for input in inputs {
                let expected = fresh.tokenize(input).unwrap();
                assert_eq!(session.tokenize(input).unwrap(), expected.as_slice());
                // Served from the cache for the same input.
                assert_eq!(session.tokenize(input).unwrap(), expected.as_slice());
                assert_eq!(
                    tokens_to_wakati(session.tokenize(input).unwrap()),
                    expected
                        .iter()
                        .map(|token| token.surface.as_str())
                        .collect::<Vec<_>>()
                        .join(" ")
                );
                assert_eq!(session.tokenize_count(input).unwrap(), expected.len());
                assert_eq!(session.tokenize(input).unwrap(), expected.as_slice());
            }
        }

        session.reset_dictionary(fixture_dictionary()).unwrap();
        assert!(!Arc::ptr_eq(&shared, &session.tokenizer.dictionary));
        let fresh = Tokenizer::new(fixture_dictionary())
            .ignore_space(true)
            .unwrap()
            .max_grouping_len(2);
        let input = "京都東京都に行った";
        assert_eq!(
            session.tokenize(input).unwrap(),
            fresh.tokenize(input).unwrap().as_slice()
        );
    }

    #[test]
    fn session_keeps_previous_options_when_reconfiguration_fails() {
        let dictionary = Dictionary::parse("matrix\t1\t1\n0\nentry\t本\t0\t0\t1\tNOUN\n").unwrap();
        let mut session = TokenizerSession::new(dictionary, false, 0).unwrap();
        let before = session.tokenize("本本").unwrap().to_vec();
        assert!(session.set_options(true, 0).is_err());
        assert!(!session.ignore_space);
        assert!(session.set_options(true, 0).is_err());
        assert_eq!(session.tokenize("本本").unwrap(), before.as_slice());
    }
}
