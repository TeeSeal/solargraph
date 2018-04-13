module Solargraph
  class Source
    class Fragment
      include NodeMethods

      attr_reader :tree

      attr_reader :line

      attr_reader :column

      # @param source [Solargraph::Source]
      # @param line [Integer]
      # @param column [Integer]
      def initialize source, line, column, tree
        # @todo Split this object from the source. The source can change; if
        #   it does, this object's data should not.
        @source = source
        @code = source.code
        @line = line
        @column = column
        @tree = tree
      end

      def character
        @column
      end

      def position
        @position ||= Position.new(line, column)
      end

      # Get the node at the current offset.
      #
      # @return [Parser::AST::Node]
      def node
        @node ||= @tree.first
      end

      # Get the fully qualified namespace at the current offset.
      #
      # @return [String]
      def namespace
        if @namespace.nil?
          parts = []
          @tree.each do |n|
            next unless n.kind_of?(AST::Node)
            if n.type == :class or n.type == :module
              parts.unshift unpack_name(n.children[0])
            end
          end
          @namespace = parts.join('::')
        end
        @namespace
      end

      # @return [Boolean]
      def argument?
        @argument ||= !signature_position.nil?
      end

      def chained?
        if @chained.nil?
          @chained = false
          @tree.each do |n|
            @chained = true if n.type == :send
            break
          end
        end
        @chained
      end

      # @return [Fragment]
      def recipient
        return nil if signature_position.nil?
        @recipient ||= @source.fragment_at(*signature_position)
      end

      # Get the scope at the current offset.
      #
      # @return [Symbol] :class or :instance
      def scope
        if @scope.nil?
          @scope = :class
          tree = @tree.clone
          until tree.empty?
            cursor = tree.shift
            break if cursor.type == :class or cursor.type == :module
            if cursor.type == :def
              pin = @source.method_pins.select{|pin| pin.contain?(offset)}.first
              # @todo The pin should never be nil here, but we're guarding it just in case
              @scope = (pin.nil? ? :instance : pin.scope)
            end
          end
        end
        @scope
      end

      # Get the signature up to the current offset. Given the text `foo.bar`,
      # the signature at offset 5 is `foo.b`.
      #
      # @return [String]
      def signature
        @signature ||= signature_data[1]
      end

      def valid?
        @source.parsed?
      end

      def broken?
        !valid?
      end

      # Get the signature before the current word. Given the signature
      # `String.new.split`, the base is `String.new`.
      #
      # @return [String]
      def base
        if @base.nil?
          if signature.include?('.')
            if signature.end_with?('.')
              @base = signature[0..-2]
            else
              @base = signature.split('.')[0..-2].join('.')
            end
          elsif signature.include?('::')
            if signature.end_with?('::')
              @base = signature[0..-3]
            else
              @base = signature.split('::')[0..-2].join('::')
            end
          else
            # @base = signature
            @base = ''
          end
        end
        @base
      end

      # @return [String]
      def root
        @root ||= signature.split('.').first
      end

      # @return [String]
      def chain
        @chain ||= signature.split('.')[1..-1].join('.')
      end

      # @return [String]
      def base_chain
        @base_chain ||= signature.split('.')[1..-2].join('.')
      end

      # @return [String]
      def whole_chain
        @whole_chain ||= whole_signature.split('.')[1..-1].join('.')
      end

      # Get the remainder of the word after the current offset. Given the text
      # `foobar` with an offset of 3, the remainder is `bar`.
      #
      # @return [String]
      def remainder
        @remainder ||= remainder_at(offset)
      end

      # Get the whole word at the current offset, including the remainder.
      # Given the text `foobar.baz`, the whole word at any offset from 0 to 6
      # is `foobar`.
      #
      # @return [String]
      def whole_word
        @whole_word ||= word + remainder
      end

      # Get the whole signature at the current offset, including the final
      # word and its remainder.
      #
      # @return [String]
      def whole_signature
        @whole_signature ||= signature + remainder
      end

      # Get the entire phrase up to the current offset. Given the text
      # `foo[bar].baz()`, the phrase at offset 10 is `foo[bar].b`.
      #
      # @return [String]
      def phrase
        @phrase ||= @code[signature_data[0]..offset]
      end

      # Get the word before the current offset. Given the text `foo.bar`, the
      # word at offset 6 is `ba`.
      def word
        @word ||= word_at(offset)
      end

      # True if the current offset is inside a string.
      #
      # @return [Boolean]
      def string?
        @string ||= (node.type == :str or node.type == :dstr)
      end

      # True if the current offset is inside a comment.
      #
      # @return [Boolean]
      def comment?
        @comment = get_comment_at(offset) if @comment.nil?
        @comment
      end

      # Get the range of the word up to the current offset.
      #
      # @return [Range]
      def word_range
        @word_range ||= word_range_at(offset, false)
      end

      # Get the range of the whole word at the current offset, including its
      # remainder.
      #
      # @return [Range]
      def whole_word_range
        @whole_word_range ||= word_range_at(offset, true)
      end

      def block
        @block ||= @source.locate_block_pin(line, character)
      end

      # Get an array of all the local variables in the source that are visible
      # from the current offset.
      #
      # @return [Array<Solargraph::Pin::LocalVariable>]
      # def local_variable_pins name = nil
      # end

      def locals
        @locals ||= @source.local_variable_pins.select{|pin| pin.visible_from?(block, position)}
      end

      def calculated_signature
        @calculated_signature ||= calculate
      end

      def calculated_whole_signature
        @calculated_whole_signature ||= calculated_signature + remainder
      end

      def calculated_base
        if @calculated_base.nil?
          @calculated_base = calculated_signature[0..-2] if calculated_signature.end_with?('.')
          @calculated_base ||= calculated_signature.split('.')[0..-2].join('.')
        end
        @calculated_base
      end

      private

      def calculate
        return signature if signature.empty? or signature.nil?
        if signature.start_with?('.')
          return signature if column < 2
          # @todo Smelly exceptional case for arrays
          return signature.sub(/^\.\[\]/, 'Array.new') if signature.start_with?('.[].')
          pn = @source.node_at(line, column - 2)
          unless pn.nil?
            literal = infer_literal_node_type(pn)
            unless literal.nil?
              return "#{literal}.new#{signature}"
            end
          end
          return signature
        end
        # @todo Smelly exceptional case for integers
        base, rest = signature.split('.', 2)
        base.sub!(/^[0-9]+?$/, 'Integer.new')
        var = local_variable_pins(base).first
        unless var.nil?
          done = []
          until var.nil?
            break if done.include?(var)
            done.push var
            type = var.calculated_signature
            break if type.nil?
            base = type
            var = local_variable_pins(base).first
          end
        end
        base + (rest.nil? ? '' : ".#{rest}")
      end

      # @todo DRY this method. It exists in ApiMap.
      # @return [Array<Solargraph::Pin::Base>]
      def prefer_non_nil_variables pins
        result = []
        nil_pins = []
        pins.each do |pin|
          if pin.nil_assignment? and pin.return_type.nil?
            nil_pins.push pin
          else
            result.push pin
          end
        end
        result + nil_pins
      end

      # @return [Integer]
      def offset
        @offset ||= get_offset(line, column)
      end

      def get_offset line, column
        Position.line_char_to_offset(@code, line, column)
      end

      def get_position_at(offset)
        pos = Position.from_offset(@code, offset)
        [pos.line, pos.character]
      end

      def signature_data
        @signature_data ||= get_signature_data_at(offset)
      end

      def get_signature_data_at index
        brackets = 0
        squares = 0
        parens = 0
        signature = ''
        index -=1
        in_whitespace = false
        while index >= 0
          break if index > 0 and comment?
          unless !in_whitespace and string?
            break if brackets > 0 or parens > 0 or squares > 0
            char = @code[index, 1]
            break if char.nil? # @todo Is this the right way to handle this?
            if brackets.zero? and parens.zero? and squares.zero? and [' ', "\r", "\n", "\t"].include?(char)
              in_whitespace = true
            else
              if brackets.zero? and parens.zero? and squares.zero? and in_whitespace
                unless char == '.' or @code[index+1..-1].strip.start_with?('.')
                  old = @code[index+1..-1]
                  nxt = @code[index+1..-1].lstrip
                  index += (@code[index+1..-1].length - @code[index+1..-1].lstrip.length)
                  break
                end
              end
              if char == ')'
                parens -=1
              elsif char == ']'
                squares -=1
              elsif char == '}'
                brackets -= 1
              elsif char == '('
                parens += 1
              elsif char == '{'
                brackets += 1
              elsif char == '['
                squares += 1
                signature = ".[]#{signature}" if squares == 0 and @code[index-2] != '%'
              end
              if brackets.zero? and parens.zero? and squares.zero?
                break if ['"', "'", ',', ';', '%'].include?(char)
                signature = char + signature if char.match(/[a-z0-9:\._@\$]/i) and @code[index - 1] != '%'
                break if char == '$'
                if char == '@'
                  signature = "@#{signature}" if @code[index-1, 1] == '@'
                  break
                end
              end
              in_whitespace = false
            end
          end
          index -= 1
        end
        # @todo Smelly exceptional case for numbers
        [index + 1, signature]
      end

      # Determine if the specified index is inside a comment.
      #
      # @return [Boolean]
      def get_comment_at(index)
        return false if string?
        # line, col = get_position_at(index)
        @source.comments.each do |c|
          return true if index > c.location.expression.begin_pos and index <= c.location.expression.end_pos
        end
        false
      end

      # Select the word that directly precedes the specified index.
      # A word can only consist of letters, numbers, and underscores.
      #
      # @param index [Integer]
      # @return [String]
      def word_at index
        @code[beginning_of_word_at(index)..index - 1]
      end

      def beginning_of_word_at index
        cursor = index - 1
        # Words can end with ? or !
        if @code[cursor, 1] == '!' or @code[cursor, 1] == '?'
          cursor -= 1
        end
        while cursor > -1
          char = @code[cursor, 1]
          break if char.nil? or char.strip.empty?
          break unless char.match(/[a-z0-9_]/i)
          cursor -= 1
        end
        # Words can begin with @@, @, $, or :
        if cursor > -1
          if cursor > 0 and @code[cursor - 1, 2] == '@@'
            cursor -= 2
          elsif @code[cursor, 1] == '@' or @code[cursor, 1] == '$'
            cursor -= 1
          elsif @code[cursor, 1] == ':' and (cursor == 0 or @code[cursor - 1, 2] != '::')
            cursor -= 1
          end
        end
        cursor + 1
      end

      # @return Solargraph::Source::Range
      def word_range_at index, whole
        cursor = beginning_of_word_at(index)
        start_offset = cursor
        start_offset -= 1 if (start_offset > 1 and @code[start_offset - 1] == ':') and (start_offset == 1 or @code[start_offset - 2] != ':')
        cursor = index
        if whole
          while cursor < @code.length
            char = @code[cursor, 1]
            break if char.nil? or char == ''
            break unless char.match(/[a-z0-9_\?\!]/i)
            cursor += 1
          end
        end
        end_offset = cursor
        end_offset = start_offset if end_offset < start_offset
        start_pos = get_position_at(start_offset)
        end_pos = get_position_at(end_offset)
        Solargraph::Source::Range.from_to(start_pos[0], start_pos[1], end_pos[0], end_pos[1])
      end

      def remainder_at index
        cursor = index
        while cursor < @code.length
          char = @code[cursor, 1]
          break if char.nil? or char == ''
          break unless char.match(/[a-z0-9_\?\!]/i)
          cursor += 1
        end
        @code[index..cursor-1]
      end

      def signature_position
        if @signature_position.nil?
          open_parens = 0
          cursor = offset - 1
          while cursor >= 0
            break if cursor < 0
            if @code[cursor] == ')'
              open_parens -= 1
            elsif @code[cursor] == '('
              open_parens += 1
            end
            break if open_parens == 1
            cursor -= 1
          end
          if cursor >= 0
            @signature_position = get_position_at(cursor)
          end
        end
        @signature_position
      end
    end
  end
end
