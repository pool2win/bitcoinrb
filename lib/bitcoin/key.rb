# Porting part of the code from bitcoin-ruby. see the license.
# https://github.com/lian/bitcoin-ruby/blob/master/COPYING

module Bitcoin

  # bitcoin key class
  class Key

    PUBLIC_KEY_SIZE = 65
    COMPRESSED_PUBLIC_KEY_SIZE = 33
    SIGNATURE_SIZE = 72
    COMPACT_SIGNATURE_SIZE = 65

    attr_accessor :priv_key
    attr_accessor :pubkey
    attr_accessor :key_type
    attr_reader :secp256k1_module

    TYPES = {uncompressed: 0x00, compressed: 0x01, p2pkh: 0x10, p2wpkh: 0x11, pw2pkh_p2sh: 0x12}

    MIN_PRIV_KEy_MOD_ORDER = 0x01
    # Order of secp256k1's generator minus 1.
    MAX_PRIV_KEY_MOD_ORDER = ECDSA::Group::Secp256k1.order - 1

    # initialize private key
    # @param [String] priv_key a private key with hex format.
    # @param [String] pubkey a public key with hex format.
    # @param [Integer] key_type a key type which determine address type.
    # @param [Boolean] compressed [Deprecated] whether public key is compressed.
    # @return [Bitcoin::Key] a key object.
    def initialize(priv_key: nil, pubkey: nil, key_type: nil, compressed: true)
      puts "[Warning] Use key_type parameter instead of compressed. compressed parameter removed in the future." if key_type.nil? && !compressed.nil? && pubkey.nil?
      if key_type
        @key_type = key_type
        compressed = @key_type != TYPES[:uncompressed]
      else
        @key_type = compressed ? TYPES[:compressed] : TYPES[:uncompressed]
      end
      @secp256k1_module =  Bitcoin.secp_impl
      @priv_key = priv_key
      if @priv_key
        raise ArgumentError, 'private key is not on curve' unless validate_private_key_range(@priv_key)
      end
      if pubkey
        @pubkey = pubkey
      else
        @pubkey = generate_pubkey(priv_key, compressed: compressed) if priv_key
      end
    end

    # generate key pair
    def self.generate(key_type = TYPES[:compressed])
      priv_key, pubkey = Bitcoin.secp_impl.generate_key_pair
      new(priv_key: priv_key, pubkey: pubkey, key_type: key_type)
    end

    # import private key from wif format
    # https://en.bitcoin.it/wiki/Wallet_import_format
    def self.from_wif(wif)
      hex = Base58.decode(wif)
      raise ArgumentError, 'data is too short' if hex.htb.bytesize < 4
      version = hex[0..1]
      data = hex[2...-8].htb
      checksum = hex[-8..-1]
      raise ArgumentError, 'invalid version' unless version == Bitcoin.chain_params.privkey_version
      raise ArgumentError, 'invalid checksum' unless Bitcoin.calc_checksum(version + data.bth) == checksum
      key_len = data.bytesize
      if key_len == COMPRESSED_PUBLIC_KEY_SIZE && data[-1].unpack('C').first == 1
        key_type = TYPES[:compressed]
        data = data[0..-2]
      elsif key_len == 32
        key_type = TYPES[:uncompressed]
      else
        raise ArgumentError, 'Wrong number of bytes for a private key, not 32 or 33'
      end
      new(priv_key: data.bth, key_type: key_type)
    end

    # export private key with wif format
    def to_wif
      version = Bitcoin.chain_params.privkey_version
      hex = version + priv_key
      hex += '01' if compressed?
      hex += Bitcoin.calc_checksum(hex)
      Base58.encode(hex)
    end

    # sign +data+ with private key
    # @param [String] data a data to be signed with binary format
    # @return [String] signature data with binary format
    def sign(data)
      secp256k1_module.sign_data(data, priv_key)
    end

    # verify signature using public key
    # @param [String] sig signature data with binary format
    # @param [String] origin original message
    # @return [Boolean] verify result
    def verify(sig, origin)
      return false unless valid_pubkey?
      begin
        sig = ecdsa_signature_parse_der_lax(sig)
        secp256k1_module.verify_sig(origin, sig, pubkey)
      rescue Exception
        false
      end
    end

    # get hash160 public key.
    def hash160
      Bitcoin.hash160(pubkey)
    end

    # get pay to pubkey hash address
    # @deprecated
    def to_p2pkh
      Bitcoin::Script.to_p2pkh(hash160).addresses.first
    end

    # get pay to witness pubkey hash address
    # @deprecated
    def to_p2wpkh
      Bitcoin::Script.to_p2wpkh(hash160).addresses.first
    end

    # get p2wpkh address nested in p2sh.
    # @deprecated
    def to_nested_p2wpkh
      Bitcoin::Script.to_p2wpkh(hash160).to_p2sh.addresses.first
    end

    def compressed?
      key_type != TYPES[:uncompressed]
    end

    # generate pubkey ec point
    # @return [ECDSA::Point]
    def to_point
      p = pubkey
      p ||= generate_pubkey(priv_key, compressed: compressed)
      ECDSA::Format::PointOctetString.decode(p.htb, Bitcoin::Secp256k1::GROUP)
    end

    # check +pubkey+ (hex) is compress or uncompress pubkey.
    def self.compress_or_uncompress_pubkey?(pubkey)
      p = pubkey.htb
      return false if p.bytesize < COMPRESSED_PUBLIC_KEY_SIZE
      case p[0]
        when "\x04"
          return false unless p.bytesize == PUBLIC_KEY_SIZE
        when "\x02", "\x03"
          return false unless p.bytesize == COMPRESSED_PUBLIC_KEY_SIZE
        else
          return false
      end
      true
    end

    # check +pubkey+ (hex) is compress pubkey.
    def self.compress_pubkey?(pubkey)
      p = pubkey.htb
      p.bytesize == COMPRESSED_PUBLIC_KEY_SIZE && ["\x02", "\x03"].include?(p[0])
    end

    # check +sig+ is low.
    def self.low_signature?(sig)
      s = sig.unpack('C*')
      len_r = s[3]
      len_s = s[5 + len_r]
      val_s = s.slice(6 + len_r, len_s)
      max_mod_half_order = [
          0x7f,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
          0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
          0x5d,0x57,0x6e,0x73,0x57,0xa4,0x50,0x1d,
          0xdf,0xe9,0x2f,0x46,0x68,0x1b,0x20,0xa0]
      compare_big_endian(val_s, [0]) > 0 &&
          compare_big_endian(val_s, max_mod_half_order) <= 0
    end


    # check +sig+ is correct der encoding.
    # This function is consensus-critical since BIP66.
    def self.valid_signature_encoding?(sig)
      return false if sig.bytesize < 9 || sig.bytesize > 73 # Minimum and maximum size check

      s = sig.unpack('C*')

      return false if s[0] != 0x30 || s[1] != s.size - 3 # A signature is of type 0x30 (compound). Make sure the length covers the entire signature.

      len_r = s[3]
      return false if 5 + len_r >= s.size # Make sure the length of the S element is still inside the signature.

      len_s = s[5 + len_r]
      return false unless len_r + len_s + 7 == s.size #Verify that the length of the signature matches the sum of the length of the elements.

      return false unless s[2] == 0x02 # Check whether the R element is an integer.

      return false if len_r == 0 # Zero-length integers are not allowed for R.

      return false unless s[4] & 0x80 == 0 # Negative numbers are not allowed for R.

      # Null bytes at the start of R are not allowed, unless R would otherwise be interpreted as a negative number.
      return false if len_r > 1 && (s[4] == 0x00) && (s[5] & 0x80 == 0)

      return false unless s[len_r + 4] == 0x02 # Check whether the S element is an integer.

      return false if len_s == 0 # Zero-length integers are not allowed for S.
      return false unless (s[len_r + 6] & 0x80) == 0 # Negative numbers are not allowed for S.

      # Null bytes at the start of S are not allowed, unless S would otherwise be interpreted as a negative number.
      return false if len_s > 1 && (s[len_r + 6] == 0x00) && (s[len_r + 7] & 0x80 == 0)

      true
    end

    # fully validate whether this is a valid public key (more expensive than IsValid())
    def fully_valid_pubkey?
      return false unless valid_pubkey?
      point = ECDSA::Format::PointOctetString.decode(pubkey.htb, ECDSA::Group::Secp256k1)
      ECDSA::Group::Secp256k1.valid_public_key?(point)
    end

    private

    def self.compare_big_endian(c1, c2)
      c1, c2 = c1.dup, c2.dup # Clone the arrays

      while c1.size > c2.size
        return 1 if c1.shift > 0
      end

      while c2.size > c1.size
        return -1 if c2.shift > 0
      end

      c1.size.times{|idx| return c1[idx] - c2[idx] if c1[idx] != c2[idx] }
      0
    end

    # generate publick key from private key
    # @param [String] privkey a private key with string format
    # @param [Boolean] compressed pubkey compressed?
    # @return [String] a pubkey which generate from privkey
    def generate_pubkey(privkey, compressed: true)
      private_key = ECDSA::Format::IntegerOctetString.decode(privkey.htb)
      public_key = ECDSA::Group::Secp256k1.generator.multiply_by_scalar(private_key)
      pubkey = ECDSA::Format::PointOctetString.encode(public_key, compression: compressed)
      pubkey.bth
    end

    # check private key range.
    def validate_private_key_range(private_key)
      value = private_key.to_i(16)
      MIN_PRIV_KEy_MOD_ORDER <= value && value <= MAX_PRIV_KEY_MOD_ORDER
    end

    # Supported violations include negative integers, excessive padding, garbage
    # at the end, and overly long length descriptors. This is safe to use in
    # Bitcoin because since the activation of BIP66, signatures are verified to be
    # strict DER before being passed to this module, and we know it supports all
    # violations present in the blockchain before that point.
    def ecdsa_signature_parse_der_lax(sig)
      sig_array = sig.unpack('C*')
      len_r = sig_array[3]
      r = sig_array[4...(len_r+4)].pack('C*').bth
      len_s = sig_array[len_r + 5]
      s = sig_array[(len_r + 6)...(len_r + 6 + len_s)].pack('C*').bth
      ECDSA::Signature.new(r.to_i(16), s.to_i(16)).to_der
    end

    def valid_pubkey?
      !pubkey.nil? && pubkey.size > 0
    end

  end

end
