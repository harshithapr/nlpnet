# -*- coding: utf-8 -*-

"""
A neural network for the language modeling task, aimed 
primiraly at inducing word representations.
"""

# import numpy as np
# cimport numpy as np

import utils

cdef class LanguageModel(Network): 
    
    # sizes and learning rates
    cdef int half_window
    
    # data for statistics during training. 
    cdef int total_items
    
    # pool of random numbers (used for efficiency)
    cdef np.ndarray random_pool
    cdef int next_random

    # file where to save model (Attardi)
    cdef public char* filename
    
    @classmethod
    def create_new(cls, feature_tables, int word_window, int hidden_size):
        """
        Creates a new neural network.
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
        output_weights = np.random.uniform(-high, high, (hidden_size))
        high = 0.1
        output_bias = np.random.uniform(-high, high, (1))
        
        net = LanguageModel(word_window, input_size, hidden_size, 
                            hidden_weights, hidden_bias, output_weights, output_bias)
        net.feature_tables = feature_tables
        
        return net
    
    def __init__(self, word_window, input_size, hidden_size, 
                 hidden_weights, hidden_bias, output_weights, output_bias):
        """
        This function isn't expected to be directly called.
        Instead, use the classmethods load_from_file or 
        create_new.
        """
        self.learning_rate = 0
        #self.learning_rate_features = np.zeros(len(self.feature_tables))
        self.learning_rate_features = 0
        
        self.word_window_size = word_window
        self.half_window = self.word_window_size / 2
        self.input_size = input_size
        self.hidden_size = hidden_size
        
        self.hidden_weights = hidden_weights
        self.hidden_bias = hidden_bias
        self.output_weights = output_weights
        self.output_bias = output_bias
        self.filename = ''      # Attardi
    
    def _generate_token(self):
        """
        Generates randomly a token to serve as a negative example.
        """
        if self.next_random == len(self.random_pool):
            self._new_random_pool()
        
        token = self.random_pool[self.next_random]
        self.next_random += 1
        
        return token
        
    
    def _train_pair(self, example):
        """
        Trains the network with a pair of positive/negative examples.
        The negative one is randomly generated.
        """
        cdef np.ndarray[INT_t, ndim=1] token
        cdef int i, j
        cdef np.ndarray[FLOAT_t, ndim=2] table
        
        middle_token = example[self.half_window]
        while True:
            # ensure to get a different word
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
        
        error = max(0, neg_score - pos_score + 1)
        self.error += error
        self.total_items += 1
        if error == 0: 
            self.skips += 1
            return
        
        # perform the correction
        # gradient for the positive example is +1, for the negative one is -1
        # (remember the network still has the values of the negative example) 
        
        # hidden gradients (the derivative of tanh(x) is 1 - tanh^2(x))
        # hidden_neg_grads = (1 - self.hidden_values ** 2) * (- self.output_weights)
        # hidden_pos_grads = (1 - pos_hidden_values ** 2) * self.output_weights
        hidden_neg_grads = hardtanhe(self.hidden_values) * (- self.output_weights)
        hidden_pos_grads = hardtanhe(pos_hidden_values) * self.output_weights
        
        # input gradients
        input_neg_grads = self.learning_rate_features * hidden_neg_grads.dot(self.hidden_weights)
        input_pos_grads = self.learning_rate_features * hidden_pos_grads.dot(self.hidden_weights)
        
        # weight adjustment
        # output bias is left unchanged -- a correction would imply in bias += +delta -delta
        self.output_weights += self.learning_rate * (pos_hidden_values - self.hidden_values) 
        
        # hidden weights
        # grad_matrix = np.tile(hidden_neg_grads, (self.input_size, 1)).T
        # hidden_neg_deltas = grad_matrix * self.input_values
        hidden_neg_deltas = hidden_neg_grads.T.dot(self.input_values)
        
        # grad_matrix = np.tile(hidden_pos_grads, (self.input_size, 1)).T
        # hidden_pos_deltas = grad_matrix * pos_input_values
        hidden_pos_deltas = hidden_pos_grads.T.dot(pos_input_values)
        
        self.hidden_weights += self.learning_rate * (hidden_neg_deltas + hidden_pos_deltas)
        self.hidden_bias += self.learning_rate * (hidden_neg_grads + hidden_pos_grads)
        
        # this tracks where the deltas for the next table begins
        # (used for efficiency reasons)
        cdef int start_from = 0
             
        for i, token in enumerate(example):
            for j, table in enumerate(self.feature_tables):
                # this is the column for the i-th position in the window
                # regarding features from the j-th table
                if i == self.half_window:
                    # this is the middle position. apply negative and positive deltas separately
                    neg_deltas = input_neg_grads[start_from:start_from + table.shape[1]]
                    pos_deltas = input_pos_grads[start_from:start_from + table.shape[1]]
                    
                    table[negative_token[j]] += neg_deltas
                    table[middle_token[j]] += pos_deltas
                    
                else:
                    # this is not the middle position. both deltas apply.
                    deltas = input_neg_grads[start_from:start_from + table.shape[1]] + \
                             input_pos_grads[start_from:start_from + table.shape[1]]
                
                    table[token[j]] += deltas
                
                start_from += table.shape[1]
    
    def _new_random_pool(self):            
        """
        Creates a pool of random indices, used for negative examples.
        Indices are generated at batches for efficiency.
        """
        self.random_pool = [np.random.random_integers(0, table.shape[0] - 1, 1000) 
                                    for table in self.feature_tables]
        self.next_random = 0
                
                
    def train(self, list sentences, int iterations, int iterations_between_reports):
        """
        Trains the language model over the given sentences.
        """
        # index containing how many tokens are there in the corpus, per sentence
        # useful for sampling tokens with equal probability from the whole corpus
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
        for batch in xrange(num_batches):
            samples = np.random.random_integers(0, max_token, 1000)
            
            for sample in samples:
                # find which sentence in the corpus the sample token belongs to
                sentence_num = index.searchsorted(sample)
                sentence = sentences[sentence_num]
                
                # the position of the token within the sentence
                token_position = sample - index[sentence_num] + len(sentence) - 1
                
                # extract the window around the token
                window = self._extract_window(sentence, token_position)
                
                self._train_pair(window)
            
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
        Extracts a token window from the sentence, with the size equal to the
        network's window size. This function takes care of creating padding as necessary.
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
        
        nn = LanguageModel(word_window_size, input_size, hidden_size, 
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

