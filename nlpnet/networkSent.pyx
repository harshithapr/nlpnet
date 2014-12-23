# -*- coding: utf-8 -*- 

"""
A neural network for sentiment specific language model, aimed 
at inducing sentiment-specific word representations.
@see Tang et al. 2014. Learning Sentiment-SpecificWord Embedding for Twitter Sentiment Classification.
http://aclweb.org/anthology/P14-1146
"""

# import numpy as np
# cimport numpy as np

import utils

cdef class SentimentModel(Network): 
    
    # sizes and learning rates
    cdef int half_window
    
    # data for statistics during training. 
    cdef int total_items
    
    # cumulative AdaGrad gradients
    cdef np.ndarray neg_hidden_adagrads, pos_hidden_adagrads

    # pool of random numbers (used for efficiency)
    cdef np.ndarray random_pool
    cdef int next_random

    # file where to save model (Attardi)
    cdef public char* filename
    
    # polarities of each tweet
    cdef list polarities

    # alpha parameter
    cdef double alpha

    @classmethod
    def create_new(cls, feature_tables, polarities, int word_window, int hidden_size, float alpha):
        """
        Creates a new neural network.
        :param word_window: defaut 3
        :param hidden_size: default 20
        :param alpha: default 0.5
        """
        # sum the number of features in all tables 
        cdef int input_size = sum(table.shape[1] for table in feature_tables)
        input_size *= word_window
        
        # creates the weight matrices
        high = 2.38 / np.sqrt(input_size) # [Bottou-88]
        #high = 0.1              # Fonseca
        hidden_weights = np.random.uniform(-high, high, (hidden_size, input_size))
        high = 2.38 / np.sqrt(hidden_size) # [Bottou-88]
        #high = 0.1              # Fonseca
        hidden_bias = np.random.uniform(-high, high, (hidden_size))
        # There are two output weights: syntactic and sentiment
        output_weights = np.random.uniform(-high, high, (2, hidden_size))
        high = 0.1
        output_bias = np.random.uniform(-high, high, (2))
        
        net = SentimentModel(word_window, input_size, hidden_size, 
                             hidden_weights, hidden_bias, output_weights, output_bias)
        net.feature_tables = feature_tables
        net.polarities = polarities
        net.alpha = alpha

        return net
    
    def __init__(self, word_window, input_size, hidden_size, 
                 hidden_weights, hidden_bias, output_weights, output_bias):
        """
        This function isn't expected to be directly called.
        Instead, use the class methods load_from_file or create_new.
        """
        # These will be set from arguments --l and --lf
        self.learning_rate = 0.1
        self.learning_rate_features = 0.1
        
        self.word_window_size = word_window
        self.half_window = self.word_window_size / 2
        self.input_size = input_size
        self.hidden_size = hidden_size
        
        self.hidden_weights = hidden_weights
        self.hidden_bias = hidden_bias
        self.output_weights = output_weights
        self.output_bias = output_bias
        self.filename = ''      # Attardi
    
        # cumulative AdaGrad
        self.neg_hidden_adagrads = np.zeros(hidden_size)
        self.pos_hidden_adagrads = np.zeros(hidden_size)

    def _generate_token(self):
        """
        Generates randomly the start index of an ngram to use as a negative example.
        """
        if self.next_random == len(self.random_pool):
            self._new_random_pool()
        
        token = self.random_pool[self.next_random]
        self.next_random += 1
        
        return token
        
    
    def _train_pair(self, example, polarity, size):
        """
        Trains the network with a pair of positive/negative examples.
        The negative one is randomly generated.
	:param example: the positive example, i.e. a list of a list of token IDs
        :param polarity: 1 for positive, -1 for negative sentences.
	:param size: size of ngram to generate for replacing window center
        """
        cdef np.ndarray[INT_t, ndim=1] token
        cdef int i, j
        cdef np.ndarray[FLOAT_t, ndim=2] table
        
        # a token is a list of feature IDs.
        # token[0] is the WordDictionary index of the word
        middle_token = example[self.half_window]

        if size == 1:
	   # ensure to generate a different word
            while True:
                variant = self._generate_token()
                if variant != middle_token[0]:
                    break

        pos_input_values = self.lookup(example)
        pos_score = self.run(pos_input_values)
        pos_hidden_values = self.hidden_values
        
        negative_token = np.array([variant])
        example[self.half_window] = negative_token
        neg_score = self.run(self.lookup(example))
        
        # put the original token back
        example[self.half_window] = middle_token
        
        errorCW = max(0, 1 - pos_score[0] + neg_score[0])
        errorUS = max(0, 1 - polarity * pos_score[1] + polarity * neg_score[1])
        error = self.alpha * errorCW + (1 - self.alpha) * errorUS
        self.error += error
        self.total_items += 1
        if error == 0: 
            self.skips += 1
            return
        
        # perform the correction
        # (remember the network still has the values of the negative example) 

        # negative gradient for the positive example is +1, for the negative one is -1
        # @see A.8 in Collobert et al. 2011.
        pos_score_grads = np.array([0, 0])
        neg_score_grads = np.array([0, 0])
        if (errorCW > 0):
            pos_score_grads[0] = 1
            neg_score_grads[0] = -1
        if (errorUS > 0):
            pos_score_grads[1] = 1
            neg_score_grads[1] = -1
        
        # Summary:
        # output_bias_grads = score_grads
        # output_weights_grads = score_grads.T * hidden_values
        # hidden_grads = activationError(hidden_values) * score_grads.T.dot(output_weights)
        # hidden_bias_grads = hidden_grads
        # hidden_weights_grads = hidden_grads.T * input_values
        # input_grads = hidden_grads.dot(hidden_weights)

        # Output layer
        # CHECKME: summing they cancel each other:
        cdef np.ndarray output_bias_grads = pos_score_grads + neg_score_grads
        # (2) x (hidden_size) = (2, hidden_size)
        cdef np.ndarray output_weights_grads = pos_score_grads.T.dot(pos_hidden_values) + neg_score_grads.T.dot(self.hidden_values)

        # Hidden layer
        # (2) x (2, hidden_size) = (hidden_size)
        neg_hidden_grads = hardtanhe(self.hidden_values) * neg_score_grads.dot(self.output_weights)
        pos_hidden_grads = hardtanhe(pos_hidden_values) * pos_score_grads.dot(self.output_weights)

        # Input layer
        cdef np.ndarray neg_hidden_weights_grads = neg_hidden_grads.T.dot(self.input_values)
        cdef np.ndarray pos_hidden_weights_grads = pos_hidden_grads.T.dot(pos_input_values)
        cdef np.ndarray hidden_weights_grads = neg_hidden_weights_grads + pos_hidden_weights_grads
        cdef np.ndarray hidden_bias_grads = pos_hidden_grads + neg_hidden_grads

        # weight adjustment
        self.output_weights += self.learning_rate * output_weights_grads
        self.output_bias += self.learning_rate * output_bias_grads
        
        self.hidden_weights += self.learning_rate * hidden_weights_grads
        self.hidden_bias += self.learning_rate * hidden_bias_grads
        
        # input gradients, using AdaGrad
        self.neg_hidden_adagrads += neg_hidden_grads.power(2)
	# (hidden_size) x (hidden_size, input_size) = (input_size)
        neg_input_grads = (neg_hidden_grads / self.neg_hidden_adagrads.sqrt()).dot(self.hidden_weights)

        self.pos_hidden_adagrads += pos_hidden_grads.power(2)
        pos_input_grads = (pos_hidden_grads / self.pos_hidden_adagrads.sqrt()).dot(self.hidden_weights)

        neg_input_deltas = self.learning_rate * neg_input_grads
        pos_input_deltas = self.learning_rate * pos_input_grads
        
        # this tracks where the deltas for the next table begins
        cdef int start = 0
             
        for i, token in enumerate(example):
            for j, table in enumerate(self.feature_tables):
                # this is the column for the i-th position in the window
                # regarding features from the j-th table
                neg_deltas = neg_input_deltas[start:start + table.shape[1]]
                pos_deltas = pos_input_deltas[start:start + table.shape[1]]
                    
                if i == self.half_window:
                    # this is the middle position. apply negative and positive deltas separately
                    table[negative_token[j]] += neg_deltas
                    table[middle_token[j]] += pos_deltas
                    
                else:
                    # this is not the middle position. both deltas apply.
                    table[token[j]] += neg_deltas + pos_deltas
                
                start += table.shape[1]
    
    def _new_random_pool(self):            
        """
        Creates a pool of random indices, used for negative examples.
        Indices are generated at batches for efficiency.
        """
        self.random_pool = np.array([np.random.random_integers(0, table.shape[0] - 1, 1000) 
                                    for table in self.feature_tables]).T
        self.next_random = 0

                
    def train(self, list sentences, int iterations, int iterations_between_reports):
        """
        Trains the language model over the given sentences.
        """
        # index containing how many tokens there are in the corpus up to
        # a given sentence.
        # Useful for sampling tokens with equal probability from the whole corpus
        index = np.cumsum([len(sent) for sent in sentences]) - 1
        max_token = index[-1]
        
        self._new_random_pool()
        self.error = 0
        self.skips = 0
        self.total_items = 0
        if iterations_between_reports > 0:
            batches_between_reports = max(iterations_between_reports / 1000, 1)
        
        # generate 1000 random indices at a time to save time
        # (generating 1000 integers at once takes about ten times the time for a single one)
        num_batches = iterations / 1000
        count = 0
        for batch in xrange(num_batches):
            samples = np.random.random_integers(0, max_token, 1000)
            
            for sample in samples:
                # find which sentence in the corpus the sample token belongs to
                sentence_num = index.searchsorted(sample)
                sentence = sentences[sentence_num]
                
                # the position of the token within the sentence
                token_position = sample - index[sentence_num] + len(sentence) - 1
                
                # extract a window of tokens around the given position
                window = self._extract_window(sentence, token_position)

		# ngram size changes periodically
                if count % 5 == 0:
                    size = 2
                elif count % 17 == 0:
                    size = 3
                else:
                    size = 1
        
                self._train_pair(window, self.polarities[sentence], size)
            
            if iterations_between_reports > 0 and \
               (batch % batches_between_reports == 0 or batch == num_batches - 1):
                self._print_batch_report(batch)
                self.error = 0
                self.skips = 0
                self.total_items = 0
            # save language model. Attardi
            if batch and batch % 100 == 0:
                utils.save_features_to_file(self.feature_tables[0], self.filename)
    
    def _extract_window(self, sentence, position):
        """
        Extracts a window of tokens from the sentence, with size equal to
        the network's window size.
        This function takes care of creating padding as necessary.
	:param sentence: the sentence fro which to extract the window
	:param position: the center token position
	:return: a portion of sentence centered at position
        """
        if position < self.half_window:
            num_padding = self.half_window - position
            pre_padding = np.array(num_padding * [self.padding_left])
            sentence = np.vstack((pre_padding, sentence))
            position += num_padding
        
        # number of tokens in the sentence after the position
        tokens_after = len(sentence) - position - 1
        if tokens_after < self.half_window:
            num_padding = self.half_window - tokens_after
            pos_padding = np.array(num_padding * [self.padding_right])
            sentence = np.vstack((sentence, pos_padding))
        
        return sentence[position - self.half_window : position + self.half_window + 1]
    
    def description(self):
        """
        Returns a description of the network.
        """
        table_dims = [str(t.shape[1]) for t in self.feature_tables]
        table_dims =  ', '.join(table_dims)
        
        desc = """
Word window size: %d
Feature table sizes: %s
Input layer size: %d
Hidden layer size: %d
""" % (self.word_window_size, table_dims, self.input_size, self.hidden_size)
        
        return desc
    
    def save(self, filename):
        """
        Saves the neural network to a file.
        It will save the weights, biases, sizes, and padding,
        but not feature tables.
        """
        np.savez(filename, hidden_weights=self.hidden_weights,
                 output_weights=self.output_weights,
                 hidden_bias=self.hidden_bias, output_bias=self.output_bias,
                 word_window_size=self.word_window_size, 
                 input_size=self.input_size, hidden_size=self.hidden_size,
                 padding_left=self.padding_left, padding_right=self.padding_right)
    
    
    @classmethod
    def load_from_file(cls, filename):
        """
        Loads the neural network from a file.
        It will load weights, biases, sizes and padding, but 
        not feature tables.
        """
        data = np.load(filename)
        
        # cython classes don't have the __dict__ attribute
        # so we can't do an elegant self.__dict__.update(data)
        hidden_weights = data['hidden_weights']
        hidden_bias = data['hidden_bias']
        output_weights = data['output_weights']
        output_bias = data['output_bias']
        
        word_window_size = data['word_window_size']
        input_size = data['input_size']
        hidden_size = data['hidden_size']
        
        nn = SentimentModel(word_window_size, input_size, hidden_size, 
                           hidden_weights, hidden_bias, output_weights, output_bias)
        
        nn.padding_left = data['padding_left']
        nn.padding_right = data['padding_right']
        
        return nn
    
    def _print_batch_report(self, int num):
        """
        Reports the status of the network in the given training
        epoch, including error and accuracy.
        """
        cdef float error = self.error / self.total_items
        logger = logging.getLogger("Logger")
        logger.info("%d batches   Error:   %f   " \
                    "%d out of %d corrections skipped" % (num + 1,
                                                          error,
                                                          self.skips,
                                                          self.total_items))
